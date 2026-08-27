// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SpectraCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SpectraCore", targets: ["SpectraCore"])
    ],
    targets: [
        .target(name: "SpectraCore"),
        .testTarget(name: "SpectraCoreTests", dependencies: ["SpectraCore"])
    ]
)
