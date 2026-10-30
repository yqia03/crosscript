import CryptoKit
import Darwin
import Foundation
import WorkbenchCore

struct PDFRuntimeLayout: Sendable {
    static let identifier = "babeldoc-0.6.4-py312-20261029-arm64-crosscript-v3"
    let root: URL
    init(dataRoot: URL) { root = dataRoot.appendingPathComponent("PDFRuntime", isDirectory: true) }
    var version: URL { root.appendingPathComponent(Self.identifier, isDirectory: true) }
    var python: URL { version.appendingPathComponent("python/bin/python3") }
    var assets: URL { version.appendingPathComponent("assets", isDirectory: true) }
}

struct PDFRuntimeArtifact: Codable, Sendable {
    let filename: String?
    let path: String?
    let url: URL
    let sha256: String
    let bytes: Int64
    var name: String { filename ?? path ?? "component" }
    // Only a flat, signed PDF/Bundled resource can be a local artifact source.
    // Never interpret file URLs, arbitrary hosts, encoded paths or traversal.
    var bundledFilename: String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "bundle", parts.host == "pdf", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath == parts.path else { return nil }
        let components = parts.path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 3, components[0].isEmpty, components[1] == "Bundled" else { return nil }
        let filename = String(components[2])
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        guard !filename.isEmpty, !filename.hasPrefix("."), filename.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return filename
    }
}
private struct PDFRuntimeManifest: Decodable {
    let schema: Int
    let id: String
    let engineVersion: String
    let pythonVersion: String
    let python: PDFRuntimeArtifact
    let wheels: [PDFRuntimeArtifact]
    let assets: [PDFRuntimeArtifact]
    var all: [PDFRuntimeArtifact] { [python] + wheels + assets }
    func validate() throws {
        guard schema == 1, id == PDFRuntimeLayout.identifier, engineVersion == "0.6.4", pythonVersion == "3.12.15",
              !wheels.isEmpty, !assets.isEmpty else { throw PDFRuntimeError.invalidManifest }
        for item in all {
            guard (item.url.scheme == "https" || item.bundledFilename != nil), item.url.user == nil, item.url.password == nil,
                  item.bytes > 0, item.sha256.count == 64, item.sha256.allSatisfy({ $0.isHexDigit }),
                  !item.name.hasPrefix("/"), !item.name.split(separator: "/").contains(".."), !item.name.contains("\\") else { throw PDFRuntimeError.invalidManifest }
        }
        guard wheels.allSatisfy({ $0.filename?.hasSuffix(".whl") == true && !$0.name.contains("/") }),
              assets.allSatisfy({ $0.path != nil }), Set(all.map(\.name)).count == all.count else { throw PDFRuntimeError.invalidManifest }
    }
}

/// Owns only PDFRuntime. No user PDF or provider credential is involved in component preparation.
struct PDFRuntimeInstaller: PDFRuntimePreparing {
    let layout: PDFRuntimeLayout
    let resourceDirectory: URL
    init(dataRoot: URL, resourceDirectory: URL? = nil) {
        layout = .init(dataRoot: dataRoot)
        self.resourceDirectory = resourceDirectory ?? Bundle.main.resourceURL!.appendingPathComponent("PDF")
    }
    func prepare(progress: @escaping @Sendable (PDFRuntimeProgress) -> Void) async throws -> PDFRuntimeReceipt {
        #if !arch(arm64)
        throw PDFRuntimeError.unsupportedPlatform
        #else
        guard ProcessInfo.processInfo.isOperatingSystemAtLeast(.init(majorVersion: 14, minorVersion: 2, patchVersion: 0)) else { throw PDFRuntimeError.unsupportedPlatform }
        do {
            let manifestURL = resourceDirectory.appendingPathComponent("runtime-manifest.json")
            guard let manifest = try? JSONDecoder().decode(PDFRuntimeManifest.self, from: Data(contentsOf: manifestURL)) else { throw PDFRuntimeError.invalidManifest }
            try manifest.validate()
            progress(.init(phase: .checking))
            try Self.makeOwnedDirectory(layout.root)
            if FileManager.default.fileExists(atPath: layout.version.path), (try? verifyInstalled(layout.version)) == true {
                try await healthCheck(at: layout.version)
                return .init(identifier: manifest.id, reused: true)
            }
            let downloads = layout.root.appendingPathComponent("Downloads", isDirectory: true)
            try Self.makeOwnedDirectory(downloads)
            let meter = PDFRuntimeDownloadMeter(items: manifest.all, report: progress)
            try await withThrowingTaskGroup(of: Void.self) { group in
                var iterator = manifest.all.makeIterator()
                for _ in 0..<4 { if let item = iterator.next() { group.addTask { try await Self.download(item, into: downloads, resourceDirectory: resourceDirectory, progress: { meter.update(item, bytes: $0) }); meter.complete(item) } } }
                while try await group.next() != nil {
                    if let item = iterator.next() { group.addTask { try await Self.download(item, into: downloads, resourceDirectory: resourceDirectory, progress: { meter.update(item, bytes: $0) }); meter.complete(item) } }
                }
            }
            try Task.checkCancellation()
            let build = layout.root.appendingPathComponent("Preparing-\(UUID())", isDirectory: true)
            try Self.makeOwnedDirectory(build)
            defer { try? FileManager.default.removeItem(at: build) }
            progress(.init(phase: .installing, completedFiles: 0, totalFiles: 3))
            try await PDFRuntimeCommand.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", Self.downloadURL(manifest.python, directory: downloads).path, "-C", build.path])
            progress(.init(phase: .installing, completedFiles: 1, totalFiles: 3))
            let python = build.appendingPathComponent("python/bin/python3")
            // No index, dependency resolver, build scripts or development toolchain at runtime.
            let wheelPaths = manifest.wheels.map { Self.downloadURL($0, directory: downloads).path }
            try await PDFRuntimeCommand.run(python, ["-I", "-m", "pip", "install", "--disable-pip-version-check", "--no-index", "--no-deps", "--no-compile"] + wheelPaths)
            progress(.init(phase: .installing, completedFiles: 2, totalFiles: 3))
            for item in manifest.assets {
                let destination = build.appendingPathComponent("assets").appendingPathComponent(item.name)
                try Self.makeOwnedDirectory(destination.deletingLastPathComponent())
                try FileManager.default.copyItem(at: Self.downloadURL(item, directory: downloads), to: destination)
            }
            progress(.init(phase: .verifying))
            try await healthCheck(at: build)
            try await PDFRuntimeCommand.run(python, ["-I", resourceDirectory.appendingPathComponent("runtime_inventory.py").path, "record", build.path])
            guard try verifyInstalled(build) else { throw PDFRuntimeError.integrityMismatch("installed components") }
            try Task.checkCancellation()
            // Quarantine a damaged old version only after its replacement is complete.
            if FileManager.default.fileExists(atPath: layout.version.path) {
                try FileManager.default.moveItem(at: layout.version, to: layout.root.appendingPathComponent("Invalid-\(UUID())"))
            }
            try FileManager.default.moveItem(at: build, to: layout.version)
            return .init(identifier: manifest.id, reused: false)
        } catch is CancellationError { throw PDFRuntimeError.cancelled }
        catch let error as PDFRuntimeError { throw error }
        catch { throw PDFRuntimeError.storageUnavailable }
        #endif
    }
    private func healthCheck(at directory: URL) async throws {
        try await PDFRuntimeCommand.run(directory.appendingPathComponent("python/bin/python3"), ["-I", resourceDirectory.appendingPathComponent("runtime_inventory.py").path, "health", directory.path])
    }
    private func verifyInstalled(_ directory: URL) throws -> Bool {
        struct Inventory: Decodable { let identifier: String; let files: [String: String]; let links: [String: String] }
        let inventoryURL = directory.appendingPathComponent("installed-files.json")
        guard let inventory = try? JSONDecoder().decode(Inventory.self, from: Data(contentsOf: inventoryURL)), inventory.identifier == PDFRuntimeLayout.identifier, inventory.files.count > 100 else { return false }
        for (name, hash) in inventory.files {
            try Task.checkCancellation()
            guard Self.safeRelative(name), try Self.hash(directory.appendingPathComponent(name)) == hash else { return false }
        }
        for (name, target) in inventory.links {
            guard Self.safeRelative(name), let actual = try? FileManager.default.destinationOfSymbolicLink(atPath: directory.appendingPathComponent(name).path), actual == target,
                  directory.appendingPathComponent(name).resolvingSymlinksInPath().path.hasPrefix(directory.path + "/") else { return false }
        }
        return FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("python/bin/python3").path)
    }
    private static func safeRelative(_ value: String) -> Bool { !value.hasPrefix("/") && !value.split(separator: "/").contains("..") }
    static func makeOwnedDirectory(_ url: URL) throws {
        // Resolve each existing ancestor before creating a descendant. Resolving
        // one complete URL does not reliably resolve a missing child behind a link.
        guard (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) == nil else { throw PDFRuntimeError.storageUnavailable }
        if FileManager.default.fileExists(atPath: url.path) {
            guard try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                  url.standardizedFileURL.path == url.resolvingSymlinksInPath().standardizedFileURL.path else { throw PDFRuntimeError.storageUnavailable }
        } else {
            let parent = url.deletingLastPathComponent()
            guard parent.path != url.path else { throw PDFRuntimeError.storageUnavailable }
            try makeOwnedDirectory(parent)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        }
    }
    static func downloadURL(_ item: PDFRuntimeArtifact, directory: URL) -> URL {
        // Wheels must retain their PEP 427 filename for pip. Hash is a parent directory.
        directory.appendingPathComponent(item.sha256).appendingPathComponent(item.filename ?? URL(fileURLWithPath: item.name).lastPathComponent)
    }
    static func download(_ item: PDFRuntimeArtifact, into directory: URL, configuration: URLSessionConfiguration? = nil, resourceDirectory: URL? = nil, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if item.url.scheme == "bundle", item.bundledFilename == nil { throw PDFRuntimeError.invalidManifest }
        let destination = downloadURL(item, directory: directory)
        try makeOwnedDirectory(destination.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: destination.path) {
            if try valid(destination, item: item) { progress(item.bytes); return }
            try FileManager.default.removeItem(at: destination)
        }
        if item.url.scheme == "bundle" {
            guard let filename = item.bundledFilename, let resourceDirectory else { throw PDFRuntimeError.invalidManifest }
            let bundled = resourceDirectory.appendingPathComponent("Bundled", isDirectory: true)
            let values = try bundled.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  bundled.resolvingSymlinksInPath().standardizedFileURL == resourceDirectory.resolvingSymlinksInPath().appendingPathComponent("Bundled", isDirectory: true).standardizedFileURL else { throw PDFRuntimeError.storageUnavailable }
            let source = bundled.appendingPathComponent(filename)
            guard try valid(source, item: item) else { throw PDFRuntimeError.integrityMismatch(item.name) }
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".partial-\(UUID())")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try Task.checkCancellation()
            try FileManager.default.copyItem(at: source, to: temporary)
            guard try valid(temporary, item: item) else { throw PDFRuntimeError.integrityMismatch(item.name) }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporary, to: destination)
            progress(item.bytes)
            return
        }
        let config = configuration ?? URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let temporary: URL
        do {
            let response: URLResponse
            (temporary, response) = try await session.download(for: URLRequest(url: item.url), delegate: PDFRuntimeDownloadObserver(report: progress))
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw PDFRuntimeError.downloadFailed(item.name) }
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw PDFRuntimeError.downloadFailed(item.name)
        }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard try valid(temporary, item: item) else { throw PDFRuntimeError.integrityMismatch(item.name) }
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: temporary, to: destination)
        progress(item.bytes)
    }
    static func valid(_ url: URL, item: PDFRuntimeArtifact) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == item.bytes else { return false }
        return try hash(url) == item.sha256
    }
    static func hash(_ url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { return "" }
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1024 * 1024), !data.isEmpty { try Task.checkCancellation(); digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
private final class PDFRuntimeDownloadObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let report: @Sendable (Int64) -> Void
    init(report: @escaping @Sendable (Int64) -> Void) { self.report = report }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { report(totalBytesWritten) }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(request.url?.scheme == "https" ? request : nil) }
}
private final class PDFRuntimeDownloadMeter: @unchecked Sendable {
    let lock = NSLock()
    var bytes: [String: Int64] = [:]
    var completed = Set<String>()
    let total: Int64
    let count: Int
    let report: @Sendable (PDFRuntimeProgress) -> Void
    init(items: [PDFRuntimeArtifact], report: @escaping @Sendable (PDFRuntimeProgress) -> Void) { total = items.reduce(0) { $0 + $1.bytes }; count = items.count; self.report = report }
    func update(_ item: PDFRuntimeArtifact, bytes value: Int64) { lock.lock(); bytes[item.sha256] = min(item.bytes, value); let event = snapshot(); lock.unlock(); report(event) }
    func complete(_ item: PDFRuntimeArtifact) { lock.lock(); completed.insert(item.sha256); let event = snapshot(); lock.unlock(); report(event) }
    private func snapshot() -> PDFRuntimeProgress { .init(phase: .downloading, completedBytes: bytes.values.reduce(0,+), totalBytes: total, completedFiles: completed.count, totalFiles: count) }
}
private final class PDFRuntimeCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    static func run(_ executable: URL, _ arguments: [String]) async throws {
        let control = PDFRuntimeCommand()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        let process = Process(); process.executableURL = executable; process.arguments = arguments
                        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8", "PYTHONNOUSERSITE": "1", "PYTHONDONTWRITEBYTECODE": "1"]
                        let output = Pipe(); process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
                        control.lock.lock()
                        if control.cancelled { control.lock.unlock(); throw CancellationError() }
                        control.process = process
                        do { try process.run(); control.lock.unlock() } catch { control.lock.unlock(); throw error }
                        DispatchQueue.global().asyncAfter(deadline: .now() + 180) { if process.isRunning { control.cancel() } }
                        // Drain output to prevent pipe backpressure; no service secrets are ever supplied.
                        while !output.fileHandleForReading.availableData.isEmpty {}
                        process.waitUntilExit()
                        control.lock.lock(); let cancelled = control.cancelled; control.lock.unlock()
                        guard !cancelled, process.terminationStatus == 0 else { throw cancelled ? PDFRuntimeError.cancelled : PDFRuntimeError.installationFailed }
                        continuation.resume()
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }, onCancel: { control.cancel() })
    }
    private func cancel() {
        lock.lock(); cancelled = true; let process = process; lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } }
    }
}
