// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "computer-use-mcp",
    platforms: [
        // macOS 14 is the floor: CADisplayLink (cursor overlay) and
        // SCScreenshotManager (background-safe capture) both require it.
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0")
    ],
    targets: [
        .executableTarget(
            name: "computer-use-mcp",
            dependencies: [
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources/computer-use-mcp"
        )
    ]
)
