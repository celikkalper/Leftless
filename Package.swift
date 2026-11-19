// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Leftless",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LeftlessCore", targets: ["LeftlessCore"]),
        .executable(name: "Leftless", targets: ["Leftless"]),
    ],
    targets: [
        .target(name: "LeftlessCore"),
        .executableTarget(name: "Leftless", dependencies: ["LeftlessCore"]),
        .testTarget(name: "LeftlessCoreTests", dependencies: ["LeftlessCore"]),
    ]
)
