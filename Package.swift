// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kalintisiz",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "KalintisizCore", targets: ["KalintisizCore"]),
        .executable(name: "Kalintisiz", targets: ["Kalintisiz"]),
    ],
    targets: [
        .target(name: "KalintisizCore"),
        .executableTarget(name: "Kalintisiz", dependencies: ["KalintisizCore"]),
        .testTarget(name: "KalintisizCoreTests", dependencies: ["KalintisizCore"]),
    ]
)
