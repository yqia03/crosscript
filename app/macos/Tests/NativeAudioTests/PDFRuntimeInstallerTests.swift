import CryptoKit
import Foundation
import Testing
import WorkbenchCore
@testable import TranslationWorkbench

@Suite(.serialized) struct PDFRuntimeInstallerTests {
    @Test func bundledArtifactsRejectAmbiguousAndExternalSources() throws {
        func artifact(_ value: String) -> PDFRuntimeArtifact {
            PDFRuntimeArtifact(filename: "font.ttf", path: nil, url: URL(string: value)!, sha256: String(repeating: "a", count: 64), bytes: 1)
        }
        #expect(artifact("bundle://pdf/Bundled/CrosscriptCJKSansCN-Regular.ttf").bundledFilename == "CrosscriptCJKSansCN-Regular.ttf")
        for invalid in ["bundle://other/Bundled/font.ttf", "bundle://user@pdf/Bundled/font.ttf",
                        "bundle://pdf:443/Bundled/font.ttf", "bundle://pdf/Bundled/font.ttf?q=1",
                        "bundle://pdf/Bundled/font.ttf#fragment", "bundle://pdf/Bundled/../font.ttf",
                        "bundle://pdf/Bundled/%2e%2e", "bundle://pdf/Bundled/one%2Ffont.ttf",
                        "bundle://pdf/Bundled/sub/font.ttf", "bundle://pdf/Bundled//font.ttf",
                        "bundle://pdf/Bundled/.hidden", "file:///Bundled/font.ttf"] {
            #expect(artifact(invalid).bundledFilename == nil, "Unexpected allowed source: \(invalid)")
        }
    }
    @Test func bundledArtifactCopiesVerifiedBytesWithoutHTTPAndRepairsCache() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-bundle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); RuntimeHTTPProtocol.mode = .success }
        let resources = root.appendingPathComponent("PDF"), bundled = resources.appendingPathComponent("Bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let data = Data("bundled-resource".utf8), source = bundled.appendingPathComponent("asset")
        try data.write(to: source)
        let item = PDFRuntimeArtifact(filename: "asset", path: nil, url: URL(string: "bundle://pdf/Bundled/asset")!, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
        let cache = root.appendingPathComponent("Downloads"), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RuntimeHTTPProtocol.self]; RuntimeHTTPProtocol.mode = .disconnect
        try await PDFRuntimeInstaller.download(item, into: cache, configuration: config, resourceDirectory: resources, progress: { _ in })
        let destination = PDFRuntimeInstaller.downloadURL(item, directory: cache)
        #expect(try Data(contentsOf: destination) == data)
        try Data("bad-cache".utf8).write(to: destination)
        try await PDFRuntimeInstaller.download(item, into: cache, configuration: config, resourceDirectory: resources, progress: { _ in })
        #expect(try Data(contentsOf: destination) == data)
        #expect(try Data(contentsOf: source) == data)
    }
    @Test func damagedBundledArtifactNeverFallsBackOrPublishesBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-bundle-bad-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("PDF"), bundled = resources.appendingPathComponent("Bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let expected = Data("expected".utf8), source = bundled.appendingPathComponent("asset")
        try Data("modified".utf8).write(to: source)
        let item = PDFRuntimeArtifact(filename: "asset", path: nil, url: URL(string: "bundle://pdf/Bundled/asset")!, sha256: SHA256.hash(data: expected).map { String(format: "%02x", $0) }.joined(), bytes: Int64(expected.count))
        let cache = root.appendingPathComponent("Downloads")
        await #expect(throws: PDFRuntimeError.integrityMismatch("asset")) {
            try await PDFRuntimeInstaller.download(item, into: cache, resourceDirectory: resources, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: PDFRuntimeInstaller.downloadURL(item, directory: cache).path))
        #expect(try Data(contentsOf: source) == Data("modified".utf8))
    }
    @Test func bundledSymlinksCannotEscapeSignedResources() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-bundle-links-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("PDF"), bundled = resources.appendingPathComponent("Bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let data = Data("external".utf8), outside = root.appendingPathComponent("external")
        try data.write(to: outside)
        let source = bundled.appendingPathComponent("asset")
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: outside)
        let item = PDFRuntimeArtifact(filename: "asset", path: nil, url: URL(string: "bundle://pdf/Bundled/asset")!, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
        let cache = root.appendingPathComponent("Downloads")
        await #expect(throws: PDFRuntimeError.integrityMismatch("asset")) {
            try await PDFRuntimeInstaller.download(item, into: cache, resourceDirectory: resources, progress: { _ in })
        }
        try FileManager.default.removeItem(at: source); try FileManager.default.removeItem(at: bundled)
        try FileManager.default.createSymbolicLink(at: bundled, withDestinationURL: root)
        await #expect(throws: PDFRuntimeError.storageUnavailable) {
            try await PDFRuntimeInstaller.download(item, into: cache, resourceDirectory: resources, progress: { _ in })
        }
        #expect(try Data(contentsOf: outside) == data)
    }
    @Test func cancelledBundleCopyLeavesNoPublishedArtifact() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-bundle-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = root.appendingPathComponent("PDF"), bundled = resources.appendingPathComponent("Bundled")
        try FileManager.default.createDirectory(at: bundled, withIntermediateDirectories: true)
        let data = Data("bundle".utf8); try data.write(to: bundled.appendingPathComponent("asset"))
        let item = PDFRuntimeArtifact(filename: "asset", path: nil, url: URL(string: "bundle://pdf/Bundled/asset")!, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
        let cache = root.appendingPathComponent("Downloads")
        let worker = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await PDFRuntimeInstaller.download(item, into: cache, resourceDirectory: resources, progress: { _ in })
        }
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(!FileManager.default.fileExists(atPath: PDFRuntimeInstaller.downloadURL(item, directory: cache).path))
    }
    @Test func cacheSymlinksCannotDeleteExternalFilesOrCreateExternalDirectories() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-cache-escape-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("external"), cache = root.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("asset"), data = Data("private file must remain".utf8)
        try data.write(to: sentinel)
        let item = PDFRuntimeArtifact(filename: "asset", path: nil, url: URL(string: "bundle://pdf/Bundled/asset")!, sha256: String(repeating: "a", count: 64), bytes: 1)
        let hashDirectory = cache.appendingPathComponent(item.sha256)
        try FileManager.default.createSymbolicLink(at: hashDirectory, withDestinationURL: outside)
        await #expect(throws: PDFRuntimeError.storageUnavailable) {
            try await PDFRuntimeInstaller.download(item, into: cache, resourceDirectory: root, progress: { _ in })
        }
        #expect(try Data(contentsOf: sentinel) == data)
        try FileManager.default.removeItem(at: hashDirectory); try FileManager.default.removeItem(at: cache)
        try FileManager.default.createSymbolicLink(at: cache, withDestinationURL: outside)
        await #expect(throws: PDFRuntimeError.storageUnavailable) {
            try await PDFRuntimeInstaller.download(item, into: cache, resourceDirectory: root, progress: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent(item.sha256).path))
        #expect(try Data(contentsOf: sentinel) == data)
    }
    @Test func verifiedCacheNeedsNoNetworkAndDamagedCacheCannotBeReady() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let data = Data("locked-resource".utf8), digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let item = PDFRuntimeArtifact(filename: "asset", path: nil, url: URL(string: "unavailable://offline")!, sha256: digest, bytes: Int64(data.count))
        let file = PDFRuntimeInstaller.downloadURL(item, directory: root)
        try PDFRuntimeInstaller.makeOwnedDirectory(file.deletingLastPathComponent()); try data.write(to: file)
        try await PDFRuntimeInstaller.download(item, into: root, progress: { _ in })
        #expect(try Data(contentsOf: file) == data)
        try Data("altered-content".utf8).write(to: file)
        await #expect(throws: PDFRuntimeError.downloadFailed("asset")) { try await PDFRuntimeInstaller.download(item, into: root, progress: { _ in }) }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
    @Test func networkInterruptionAndIntegrityMismatchAreRetryableWithoutPublishingBytes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-http-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); RuntimeHTTPProtocol.mode = .success }
        let data = Data("verified runtime bytes".utf8)
        let item = PDFRuntimeArtifact(filename: "resource", path: nil, url: URL(string: "https://runtime.test/resource")!, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RuntimeHTTPProtocol.self]
        RuntimeHTTPProtocol.mode = .disconnect
        await #expect(throws: PDFRuntimeError.downloadFailed("resource")) { try await PDFRuntimeInstaller.download(item, into: root, configuration: config, progress: { _ in }) }
        #expect(!FileManager.default.fileExists(atPath: PDFRuntimeInstaller.downloadURL(item, directory: root).path))
        RuntimeHTTPProtocol.mode = .corrupt
        await #expect(throws: PDFRuntimeError.integrityMismatch("resource")) { try await PDFRuntimeInstaller.download(item, into: root, configuration: config, progress: { _ in }) }
        RuntimeHTTPProtocol.mode = .success
        try await PDFRuntimeInstaller.download(item, into: root, configuration: config, progress: { _ in })
        #expect(try PDFRuntimeInstaller.valid(PDFRuntimeInstaller.downloadURL(item, directory: root), item: item))
    }
    @Test func cancelledDownloadNeverPublishesPartialResourceAndCanRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root); RuntimeHTTPProtocol.mode = .success }
        let data = Data("verified runtime bytes".utf8)
        let item = PDFRuntimeArtifact(filename: "resource", path: nil, url: URL(string: "https://runtime.test/slow")!, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: Int64(data.count))
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RuntimeHTTPProtocol.self]
        RuntimeHTTPProtocol.mode = .wait
        let worker = Task { try await PDFRuntimeInstaller.download(item, into: root, configuration: config, progress: { _ in }) }
        try await Task.sleep(for: .milliseconds(30)); worker.cancel()
        await #expect(throws: CancellationError.self) { try await worker.value }
        #expect(!FileManager.default.fileExists(atPath: PDFRuntimeInstaller.downloadURL(item, directory: root).path))
        RuntimeHTTPProtocol.mode = .success
        try await PDFRuntimeInstaller.download(item, into: root, configuration: config, progress: { _ in })
        #expect(try PDFRuntimeInstaller.valid(PDFRuntimeInstaller.downloadURL(item, directory: root), item: item))
    }
    @Test func symlinkCannotSatisfyIntegrityOrRedirectRuntimeStorage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-links-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("original"), link = root.appendingPathComponent("link")
        let data = Data("real".utf8); try data.write(to: source)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let item = PDFRuntimeArtifact(filename: "file", path: nil, url: URL(string: "https://invalid.example")!, sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), bytes: 4)
        #expect(try !PDFRuntimeInstaller.valid(link, item: item))
        let directoryLink = root.appendingPathComponent("directory")
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: root)
        #expect(throws: PDFRuntimeError.storageUnavailable) { try PDFRuntimeInstaller.makeOwnedDirectory(directoryLink) }
        #expect(try Data(contentsOf: source) == data)
    }
    @Test func incompatibleManifestFailsWithoutTouchingImportedMaterial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runtime-invalid-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("source.pdf"), data = Data("existing imported material".utf8)
        try data.write(to: source); try Data("{}".utf8).write(to: root.appendingPathComponent("runtime-manifest.json"))
        await #expect(throws: PDFRuntimeError.invalidManifest) { try await PDFRuntimeInstaller(dataRoot: root, resourceDirectory: root).prepare(progress: { _ in }) }
        #expect(try Data(contentsOf: source) == data)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("PDFRuntime").path))
    }
}

private final class RuntimeHTTPProtocol: URLProtocol, @unchecked Sendable {
    enum Mode { case success, corrupt, disconnect, wait }
    nonisolated(unsafe) static var mode: Mode = .success
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.mode == .disconnect { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let data = Data((Self.mode == .success ? "verified runtime bytes" : "corrupted runtime byte").utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "\(data.count)"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if Self.mode != .wait { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
