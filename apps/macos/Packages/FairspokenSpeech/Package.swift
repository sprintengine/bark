// swift-tools-version: 6.2
// Speech recognition on the Apple Neural Engine, shared by Bark (the dictation client)
// and Bark Server. Absorbs engine API churn in one place; both engines are pinned exactly.
//
//   FairspokenSpeech   Parakeet through FluidAudio (Core ML): the client's engine and the
//                      server's worker pool. The only code that touches FluidAudio.
//   FairspokenWhisper  Whisper through WhisperKit (Core ML), the model store under
//                      Application Support, and the client's engine that runs either family.
//                      The only code that touches WhisperKit; the server doesn't link it.
import PackageDescription

let package = Package(
    name: "FairspokenSpeech",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "FairspokenSpeech", targets: ["FairspokenSpeech"]),
        .library(name: "FairspokenWhisper", targets: ["FairspokenWhisper"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
        .package(path: "../FairspokenCore"),
    ],
    targets: [
        .target(name: "FairspokenSpeech", dependencies: [
            .product(name: "FluidAudio", package: "FluidAudio"),
            "FairspokenCore",
        ]),
        .target(name: "FairspokenWhisper", dependencies: [
            "FairspokenSpeech",
            "FairspokenCore",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        // Opt-in checks against real models (skipped unless FAIRSPOKEN_REAL_MODEL_LINK or
        // FAIRSPOKEN_REAL_WHISPER is set); not part of scripts/test.sh.
        .testTarget(name: "FairspokenSpeechTests", dependencies: [
            "FairspokenSpeech",
            "FairspokenWhisper",
            "FairspokenCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ]),
    ]
)
