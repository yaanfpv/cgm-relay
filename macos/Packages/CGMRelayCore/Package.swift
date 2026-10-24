// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CGMRelayCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CGMRelayCore", targets: ["CGMRelayCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
    ],
    targets: [
        .target(
            name: "CGMRelayCore",
            dependencies: [
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
            ]
        ),
        .testTarget(name: "CGMRelayCoreTests", dependencies: ["CGMRelayCore"]),
    ],
    swiftLanguageModes: [.v6]
)
