// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Leftless",
    defaultLocalization: "en",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LeftlessCore", targets: ["LeftlessCore"]),
        .executable(name: "Leftless", targets: ["Leftless"]),
    ],
    targets: [
        .target(name: "LeftlessCore", resources: [.process("Localizable.xcstrings")]),
        // The app's String Catalog is compiled by Xcode (project.yml); `swift run` shows the English source text.
        .executableTarget(name: "Leftless", dependencies: ["LeftlessCore"], exclude: ["Localizable.xcstrings"]),
        .testTarget(name: "LeftlessCoreTests", dependencies: ["LeftlessCore"]),
    ]
)
