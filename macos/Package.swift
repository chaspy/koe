// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Koe",
    platforms: [.macOS(.v14)],
    targets: [
        // Objective-C shim: catches NSException so AVFAudio errors do not abort the app (see MicTap.swift)
        .target(name: "KoeObjC", path: "Sources/KoeObjC"),
        // C++20 port of AudioQuality.swift, imported from koe-audio-core (off by default, see AudioCoreQuality.swift)
        .target(name: "KoeAudioCore", path: "Sources/KoeAudioCore"),
        .executableTarget(name: "Koe", dependencies: ["KoeObjC", "KoeAudioCore"], path: "Sources/Koe"),
    ],
    cxxLanguageStandard: .cxx20
)
