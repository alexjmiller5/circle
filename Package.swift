// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CircleGraph",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CircleGraph", targets: ["CircleGraph"])],
    targets: [
        .target(name: "CircleGraph", path: "nudge/nudge/Graph"),
        .testTarget(name: "CircleGraphTests", dependencies: ["CircleGraph"], path: "GraphTests")
    ]
)
