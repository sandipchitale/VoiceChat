// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceChat",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "VoiceChatKit", targets: ["VoiceChatKit"]),
        .library(name: "VoiceChatUI", targets: ["VoiceChatUI"]),
        .library(name: "VoiceChatMCPServer", targets: ["VoiceChatMCPServer"]),
        .executable(name: "voicechatd", targets: ["voicechatd"]),
        .executable(name: "voicechat-mcp", targets: ["voicechat-mcp"]),
        .executable(name: "vcp-probe", targets: ["vcp-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // Same minimum bound swift-sdk's own manifest declares, so the
        // resolved 2.102.0 pin does not change — this just makes an already
        // transitively-resolved dependency directly usable from this package.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
    ],
    targets: [
        // R-ARCH-5: no AppKit, no SwiftUI. Everything here is headlessly
        // testable. The MCP product itself has no UI-framework dependency
        // either, so depending on it here doesn't compromise that.
        .target(name: "VoiceChatKit", dependencies: [.product(name: "MCP", package: "swift-sdk")]),

        .target(name: "VoiceChatUI", dependencies: ["VoiceChatKit"]),

        .target(
            name: "VoiceChatMCPServer",
            dependencies: [
                "VoiceChatKit",
                "VoiceChatUI",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),

        .executableTarget(name: "voicechatd", dependencies: ["VoiceChatUI", "VoiceChatKit", "VoiceChatMCPServer"]),

        .executableTarget(
            name: "voicechat-mcp",
            dependencies: [
                "VoiceChatKit",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        .executableTarget(name: "vcp-probe", dependencies: ["VoiceChatKit"]),

        .testTarget(name: "VoiceChatKitTests", dependencies: ["VoiceChatKit"]),
        .testTarget(name: "VoiceChatUITests", dependencies: ["VoiceChatUI"]),
    ]
)
