// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS(.v14)],
    targets: [
        // Objective-C shim: catches NSException so AVFAudio errors do not abort the app (see MicTap.swift)
        .target(name: "KoeObjC", path: "Sources/KoeObjC"),
        .executableTarget(name: "Koe", dependencies: ["KoeObjC"], path: "Sources/Koe"),
    ]
)
