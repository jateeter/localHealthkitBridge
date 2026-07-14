// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HealthKitBridge",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "HealthKitBridge", targets: ["HealthKitBridge"]),
    ],
    targets: [
        .target(
            name: "HealthKitBridge",
            path: "Sources/HealthKitBridge"
        ),
        .testTarget(
            name: "HealthKitBridgeTests",
            dependencies: ["HealthKitBridge"],
            path: "Tests/HealthKitBridgeTests"
        ),
    ]
)
