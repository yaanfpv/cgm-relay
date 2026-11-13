// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CGMRelayCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CGMRelayCore", targets: ["CGMRelayCore"])
    ],
    targets: [
        .target(name: "CGMRelayCore"),
        .testTarget(name: "CGMRelayCoreTests", dependencies: ["CGMRelayCore"]),
    ],
    swiftLanguageModes: [.v6]
)
