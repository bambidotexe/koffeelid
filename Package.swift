// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "KoffeeLid",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KoffeeLidCore", targets: ["KoffeeLidCore"]),
        .library(name: "LidPlaneKit", targets: ["LidPlaneKit"]),
    ],
    targets: [
        .target(name: "KoffeeLidCore"),
        .target(name: "LidPlaneKit", dependencies: ["KoffeeLidCore"]),
        .testTarget(name: "KoffeeLidCoreTests", dependencies: ["KoffeeLidCore"]),
        .testTarget(name: "LidPlaneKitTests", dependencies: ["LidPlaneKit"]),
    ]
)
