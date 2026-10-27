// swift-tools-version:5.9
// udha-agent — headless Udha for Linux boxes. Compiles the app's session engine
// and mobile bridge (symlinked from ../Udha.AIDesktop, see Sources/udha-agent/Shared)
// into a daemon that appears to the iPad app as its own paired instance.
import PackageDescription

let package = Package(
    name: "udha-agent",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        // WebSocket transport (Linux Foundation's needs a libcurl Ubuntu doesn't ship).
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/vapor/websocket-kit.git", from: "2.15.0"),
    ],
    targets: [
        .executableTarget(
            name: "udha-agent",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "WebSocketKit", package: "websocket-kit"),
            ],
            path: "Sources/udha-agent",
            swiftSettings: [.define("UDHA_AGENT")]
        ),
    ]
)
