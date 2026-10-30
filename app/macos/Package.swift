// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranslationWorkbench",
    platforms: [.macOS("14.2")],
    products: [
        .library(name: "WorkbenchCore", targets: ["WorkbenchCore"]),
        .executable(name: "TranslationWorkbench", targets: ["TranslationWorkbench"]),
    ],
    targets: [
        .target(name: "WorkbenchCore"),
        .executableTarget(name: "TranslationWorkbench", dependencies: ["WorkbenchCore"], exclude: ["Resources"]),
        .testTarget(name: "WorkbenchCoreTests", dependencies: ["WorkbenchCore"]),
        .testTarget(name: "NativeAudioTests", dependencies: ["TranslationWorkbench"]),
    ],
    swiftLanguageModes: [.v5]
)
