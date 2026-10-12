// swift-tools-version:5.9
import PackageDescription
import Foundation

// whisper.cpp is linked statically from build/whisper (run scripts/build-whisper.sh first).
let whisperLib = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("build/whisper/lib").path

let package = Package(
    name: "Utter",
    platforms: [.macOS(.v13)],
    targets: [
        .systemLibrary(name: "CWhisper", path: "Sources/CWhisper"),
        .executableTarget(
            name: "Utter",
            dependencies: ["CWhisper"],
            path: "Sources/Utter",
            linkerSettings: [
                .unsafeFlags(["-L", whisperLib]),
                .linkedLibrary("whisper"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
                .linkedLibrary("ggml-cpu"),
                .linkedLibrary("ggml-metal"),
                .linkedLibrary("ggml-blas"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Foundation"),
            ]
        )
    ]
)
