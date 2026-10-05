// swift-tools-version: 6.0
import PackageDescription
import Foundation

// A preparation build shares pure Swift logic and the wire/CLI contract, but
// cannot read projects or change settings until a Windows security adapter is
// implemented. The opt-in profile exercises that same source set on a Mac.
#if os(Windows)
let portablePreparation = true
#else
let portablePreparation = ProcessInfo.processInfo.environment["CONTEXTOS_PORTABLE_BUILD"] == "1"
#endif
let preparationSettings: [SwiftSetting] = portablePreparation ? [.define("CONTEXTOS_PORTABLE_BUILD")] : []
let preparationExcludes = [
    "Platform/macOS", "Analytics", "Git", "Health", "Integration", "Registry",
    "Indexer/Indexer.swift", "Indexer/ProjectScanner.swift",
    "Service/ContextService.swift", "Service/SessionTools.swift"
]
var products: [Product] = [
    .library(name: "ContextOSCore", targets: ["ContextOSCore"]),
    .executable(name: "contextos", targets: ["contextos"]),
    .executable(name: "contextos-mcp", targets: ["contextos-mcp"])
]
var targets: [Target] = [
    .target(name: "CWindowsNative", linkerSettings: [
        .linkedLibrary("Advapi32", .when(platforms: [.windows])),
        .linkedLibrary("Bcrypt", .when(platforms: [.windows]))
    ]),
    .target(name: "ContextOSCore", dependencies: ["CWindowsNative"], exclude: portablePreparation ? preparationExcludes : [], swiftSettings: preparationSettings),
    .executableTarget(name: "contextos", dependencies: ["ContextOSCore", .product(name: "ArgumentParser", package: "swift-argument-parser")], swiftSettings: preparationSettings),
    .executableTarget(name: "contextos-mcp", dependencies: ["ContextOSCore"], swiftSettings: preparationSettings),
    .testTarget(name: "ContextOSPortableTests", dependencies: ["ContextOSCore"], swiftSettings: preparationSettings)
]
if !portablePreparation {
    products.append(.executable(name: "ContextOSApp", targets: ["ContextOSApp"]))
    targets += [
        .executableTarget(name: "ContextOSApp", dependencies: ["ContextOSCore"]),
        .executableTarget(name: "contextos-bench", dependencies: ["ContextOSCore"], path: "Benchmarks"),
        .testTarget(name: "ContextOSCoreTests", dependencies: ["ContextOSCore"])
    ]
}

let package = Package(
    name: "ContextOS",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: targets
)
