// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Studio92",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "AgentCouncil",
            targets: ["AgentCouncil"]
        ),
        .executable(name: "council",      targets: ["AgentCouncilCLI"]),
        .executable(name: "executor",     targets: ["ExecutorCLI"])
    ],
    dependencies: [
        .package(url: "https://github.com/teunlao/swift-ai-sdk.git", from: "0.17.6")
    ],
    targets: [
        .target(
            name: "AgentCouncil",
            path: "Sources/AgentCouncil"
        ),
        .executableTarget(
            name: "AgentCouncilCLI",
            dependencies: ["AgentCouncil"],
            path: "Sources/AgentCouncilCLI"
        ),
        .target(
            name: "Executor",
            dependencies: [
                .product(name: "SwiftAISDK", package: "swift-ai-sdk"),
                .product(name: "OpenAIProvider", package: "swift-ai-sdk"),
                .product(name: "AISDKProvider", package: "swift-ai-sdk")
            ],
            path: "Sources/Executor"
        ),
        .executableTarget(
            name: "ExecutorCLI",
            dependencies: ["Executor"],
            path: "Sources/ExecutorCLI"
        ),
        .target(
            name: "BuildDiagnostics",
            path: "CommandCenter/Diagnostics",
            sources: ["BuildDiagnostics.swift"]
        ),
        .target(
            name: "MultimodalEngine",
            path: "CommandCenter/Bridge",
            sources: ["MultimodalEngine.swift"]
        ),
        .testTarget(
            name: "AgentCouncilTests",
            dependencies: ["AgentCouncil"],
            path: "Tests/AgentCouncilTests"
        ),
        .testTarget(
            name: "ExecutorTests",
            dependencies: ["Executor"],
            path: "Tests/ExecutorTests"
        ),
        .testTarget(
            name: "BuildDiagnosticsTests",
            dependencies: ["BuildDiagnostics"],
            path: "Tests/BuildDiagnosticsTests"
        ),
        .testTarget(
            name: "MultimodalEngineTests",
            dependencies: ["MultimodalEngine"],
            path: "Tests/MultimodalEngineTests"
        )
    ]
)
