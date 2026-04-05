// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Orbit",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "orbit", targets: ["Orbit"]),
        .library(name: "OrbitCore", targets: ["OrbitCore"]),
    ],
    dependencies: [
        // CLI
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.7.1"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.3.1"),

        // LLM Providers
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", from: "2.2.1"),
        .package(url: "https://github.com/jamesrochabrun/SwiftOpenAI.git", from: "4.4.9"),

        // Config
        .package(url: "https://github.com/LebJe/TOMLKit.git", from: "0.6.0"),

        // Storage
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0"),

        // MCP
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),

    ],
    targets: [
        // CLI executable
        .executableTarget(
            name: "Orbit",
            dependencies: [
                "OrbitCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),

        // Core library (no MCP dependency — types, tools, engine, memory)
        .target(
            name: "OrbitCore",
            dependencies: [
                .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
                .product(name: "SwiftOpenAI", package: "SwiftOpenAI"),
                .product(name: "TOMLKit", package: "TOMLKit"),
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        // Tests
        .testTarget(
            name: "OrbitCoreTests",
            dependencies: ["OrbitCore"]
        ),
    ]
)
