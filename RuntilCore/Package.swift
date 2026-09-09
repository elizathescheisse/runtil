// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RuntilCore",
    platforms: [.iOS(.v18), .watchOS(.v11), .macOS(.v15)],
    products: [
        .library(name: "RuntilCore", targets: ["RuntilCore"])
    ],
    targets: [
        .target(name: "RuntilCore"),
        .testTarget(name: "RuntilCoreTests", dependencies: ["RuntilCore"])
    ]
)
