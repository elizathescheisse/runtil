// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RuntilCore",
    platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
    products: [
        .library(name: "RuntilCore", targets: ["RuntilCore"])
    ],
    targets: [
        .target(name: "RuntilCore"),
        .testTarget(name: "RuntilCoreTests", dependencies: ["RuntilCore"])
    ]
)
