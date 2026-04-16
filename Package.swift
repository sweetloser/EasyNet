// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "EasyNet",
    platforms: [
        .iOS(.v13),
        .macOS(.v12),
    ],
    products: [
        .library(
            name: "EasyNet",
            targets: ["EasyNet"]
        ),
        .executable(
            name: "EasyNetTerminalServerDemo",
            targets: ["EasyNetTerminalServerDemo"]
        ),
        .executable(
            name: "EasyNetTerminalClientDemo",
            targets: ["EasyNetTerminalClientDemo"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.97.1"),
    ],
    targets: [
        .target(
            name: "EasyNetTransport",
            dependencies: [
                .product(name: "NIO", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "EasyNetProtocolCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "EasyNetProtocolPlugin",
            dependencies: [
                "EasyNetTransport",
                "EasyNetProtocolCore",
            ]
        ),
        .target(
            name: "EasyNetRuntime",
            dependencies: [
                "EasyNetTransport",
                "EasyNetProtocolCore",
                "EasyNetProtocolPlugin",
            ]
        ),
        .target(
            name: "EasyNetPlugins",
            dependencies: [
                "EasyNetTransport",
                "EasyNetProtocolCore",
                "EasyNetProtocolPlugin",
                "EasyNetRuntime",
            ]
        ),
        .target(
            name: "EasyNet",
            dependencies: [
                "EasyNetTransport",
                "EasyNetProtocolCore",
                "EasyNetProtocolPlugin",
                "EasyNetRuntime",
                "EasyNetPlugins",
            ]
        ),
        .executableTarget(
            name: "EasyNetTerminalServerDemo",
            dependencies: [
                "EasyNet",
            ]
        ),
        .executableTarget(
            name: "EasyNetTerminalClientDemo",
            dependencies: [
                "EasyNet",
            ]
        ),
        .testTarget(
            name: "EasyNetTests",
            dependencies: [
                "EasyNet",
                "EasyNetPlugins",
                "EasyNetProtocolCore",
                "EasyNetProtocolPlugin",
                "EasyNetRuntime",
                "EasyNetTransport",
            ]
        ),
    ]
)
