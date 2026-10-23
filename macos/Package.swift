// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS(.v14)],
    targets: [
        // Objective-C shim: catches NSException so AVFAudio errors do not abort the app (see MicTap.swift)
        .target(name: "KoeObjC", path: "Sources/KoeObjC"),
        // Shared C++20 quality implementation, imported from koe-audio-core
        .target(name: "KoeAudioCore", path: "Sources/KoeAudioCore"),
        .executableTarget(name: "Koe", dependencies: ["KoeObjC", "KoeAudioCore"], path: "Sources/Koe"),
    ],
    cxxLanguageStandard: .cxx20
)
