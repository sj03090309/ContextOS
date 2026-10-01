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
        .executable(name: "ContextOSApp", targets: ["ContextOSApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: [
        // Pure logic. No platform / UI dependencies. Everything else is a thin adapter.
        .target(
            name: "ContextOSCore"
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
            dependencies: ["ContextOSCore"]
        ),
        // Disposable synthetic workloads; never included in the app bundle.
        .executableTarget(name: "contextos-bench", dependencies: ["ContextOSCore"], path: "Benchmarks"),
        .testTarget(
            name: "ContextOSCoreTests",
            dependencies: ["ContextOSCore"]
        )
    ]
)
