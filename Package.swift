// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CircleGraph",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "CircleGraph", targets: ["CircleGraph"]),
               .executable(name: "circle-push", targets: ["circle-push"])],
    targets: [
        .target(name: "CircleGraph", path: "nudge/nudge/Graph", resources: [.process("Resources")]),
        .testTarget(name: "CircleGraphTests", dependencies: ["CircleGraph"], path: "GraphTests"),
        // The nearby-alert push service: runs beside the Find My collector, sends straight to APNs.
        .target(name: "CirclePush", dependencies: ["CircleGraph"], path: "push/Sources"),
        .executableTarget(name: "circle-push", dependencies: ["CirclePush"], path: "push/Main"),
        .testTarget(name: "CirclePushTests", dependencies: ["CirclePush", "CircleGraph"], path: "push/Tests")
    ]
)
