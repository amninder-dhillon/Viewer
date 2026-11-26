// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Viewer",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Viewer", targets: ["Viewer"])],
    targets: [
        .target(name: "ViewerCore"),
        .executableTarget(name: "Viewer", dependencies: ["ViewerCore"]),
        .testTarget(name: "ViewerCoreTests", dependencies: ["ViewerCore"]),
        .testTarget(name: "ViewerTests", dependencies: ["Viewer", "ViewerCore"])
    ]
)
