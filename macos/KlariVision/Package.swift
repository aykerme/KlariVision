// swift-tools-version: 6.0
// Executable hedefi SwiftUI uygulamasını; test hedefi notasyon, pitch ve
// çapraz-dil parite kapılarını derler. C++ köprü/paketleme Xcode akışındadır.
import PackageDescription

let package = Package(
    name: "KlariVision",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "KlariVision", targets: ["KlariVisionApp"]),
    ],
    targets: [
        .executableTarget(
            name: "KlariVisionApp",
            swiftSettings: [.define("KLARIVISION_SWIFT_PACKAGE")]
        ),
        .testTarget(name: "KlariVisionAppTests", dependencies: ["KlariVisionApp"]),
    ]
)
