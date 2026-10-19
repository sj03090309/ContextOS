// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ContextOS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ContextOSCore", targets: ["ContextOSCore"]),
        .executable(name: "contextos", targets: ["contextos"]),
        .executable(name: "contextos-mcp", targets: ["contextos-mcp"]),
        .executable(name: "ContextOSApp", targets: ["ContextOSApp"]),
        .executable(name: "contextos-usage-bench", targets: ["contextos-usage-bench"]),
        .executable(name: "contextos-bridge-integration-host", targets: ["contextos-bridge-integration-host"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: [
        .target(name: "ContextOSUsage"),
        .target(name: "ContextOSUsageUI", dependencies: ["ContextOSUsage"]),
        .testTarget(name: "ContextOSUsageTests", dependencies: ["ContextOSCore", "ContextOSUsage"]),
        .testTarget(name: "ContextOSAppTests", dependencies: ["ContextOSApp"]),
        // Pure logic. No platform / UI dependencies. Everything else is a thin adapter.
        .target(
            name: "ContextOSCore", dependencies: ["ContextOSUsage"]
        ),
        // Thin CLI adapter over ContextOSCore. Used for development + verification.
        .executableTarget(
            name: "contextos",
            dependencies: [
                "ContextOSCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ]
        ),
        // Thin MCP (stdio JSON-RPC) adapter. Exposes ContextOS to Claude Code.
        .executableTarget(
            name: "contextos-mcp",
            dependencies: ["ContextOSCore"]
        ),
        // SwiftUI menu-bar dashboard.
        .executableTarget(
            name: "ContextOSApp",
            dependencies: ["ContextOSCore", "ContextOSUsageUI", "ContextOSUsage"]
        ),
        // Disposable synthetic workloads; never included in the app bundle.
        .executableTarget(name: "contextos-bench", dependencies: ["ContextOSCore"], path: "Benchmarks"),
        .executableTarget(name: "contextos-usage-bench", dependencies: ["ContextOSCore", "ContextOSUsage"], path: "UsageBenchmarks"),
        .executableTarget(name: "contextos-bridge-integration-host", dependencies: ["ContextOSCore", "ContextOSUsage"], path: "TestSupport/BridgeIntegrationHost"),
        .testTarget(
            name: "ContextOSCoreTests",
            dependencies: ["ContextOSCore"]
        )
    ]
)
