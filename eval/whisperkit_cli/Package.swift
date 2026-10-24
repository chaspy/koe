// swift-tools-version:5.9
// A resident helper for asr_bench.py (#180): WhisperKit (Core ML, the koe-ios engine) on the Mac.
// Built by asr_bench.py into the cache (`swift build -c release`); the version is pinned here and in
// Package.resolved. Used for measurement only; Koe itself does not depend on it.
import PackageDescription

let package = Package(
    name: "whisperkit_cli",
    platforms: [.macOS(.v14)],
    dependencies: [.package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1")],
    targets: [.executableTarget(name: "whisperkit_cli", dependencies: [.product(name: "WhisperKit", package: "WhisperKit")])]
)
