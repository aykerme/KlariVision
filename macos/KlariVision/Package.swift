// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KlariVision",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KlariVision", targets: ["KlariVisionApp"]),
    ],
    targets: [
        .executableTarget(name: "KlariVisionApp"),
    ]
)
