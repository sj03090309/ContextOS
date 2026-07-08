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
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0")
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
        .testTarget(
            name: "ContextOSCoreTests",
            dependencies: ["ContextOSCore"]
        )
    ]
)
