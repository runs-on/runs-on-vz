// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "runs-on-vz",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "runs-on-vz", targets: ["runs-on-vz"]),
    ],
    targets: [
        .executableTarget(name: "runs-on-vz"),
        .testTarget(name: "runs-on-vzTests", dependencies: ["runs-on-vz"]),
    ]
)
