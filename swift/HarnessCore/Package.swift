// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HarnessCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "HarnessCore", targets: ["HarnessCore"]),
    ],
    targets: [
        .target(name: "HarnessCore"),
        .testTarget(name: "HarnessCoreTests", dependencies: ["HarnessCore"]),
    ]
)
