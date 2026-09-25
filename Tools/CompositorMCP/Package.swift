// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CompositorMCP",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "CompositorMCPCore", targets: ["CompositorMCPCore"]),
    ],
    targets: [
        .target(name: "CompositorMCPCore"),
        .executableTarget(name: "compositor-mcp", dependencies: ["CompositorMCPCore"]),
        .testTarget(name: "CompositorMCPTests", dependencies: ["CompositorMCPCore"]),
    ]
)
