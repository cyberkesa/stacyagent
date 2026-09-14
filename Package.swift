// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "mlxagent",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "mlxagent", targets: ["MLXAgent"]),
        .executable(name: "slta-runtime", targets: ["SLTARuntimeLauncher"]),
        .library(name: "SLTACore", targets: ["SLTACore"]),
        .library(name: "SLTAIPC", targets: ["SLTAIPC"])
    ],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", .upToNextMajor(from: "3.31.4")),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "0.9.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        // ✅ Заменили MarkdownUI на Textual
        .package(url: "https://github.com/gonzalezreal/textual", from: "0.1.0")
    ],
    targets: [
        .target(
            name: "SLTACore"
        ),
        .target(
            name: "SLTAIPC"
        ),
        .executableTarget(
            name: "MLXAgent",
            dependencies: [
                "SLTACore",
                "SLTAIPC",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXHuggingFace", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                // ✅ Заменили продукт MarkdownUI на Textual
                .product(name: "Textual", package: "textual")
            ]
        ),
        .executableTarget(
            name: "SLTARuntimeLauncher",
            dependencies: ["SLTAIPC"]
        ),
        .testTarget(
            name: "MLXAgentTests",
            dependencies: ["SLTACore"]
        ),
        .testTarget(
            name: "SLTAIPCTests",
            dependencies: ["SLTAIPC"]
        )
    ]
)
