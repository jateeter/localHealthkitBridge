// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MobileSolidCompat",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "MobileSolidCompatModel", targets: ["MobileSolidCompatModel"]),
        .library(name: "MobileSolidCompatImportProbe", targets: ["MobileSolidCompatImportProbe"]),
        .library(name: "MobileSolidCompatUI", targets: ["MobileSolidCompatUI"]),
    ],
    dependencies: [
        .package(path: "../Vendor/SolidAuthSwift"),
        .package(url: "https://github.com/crspybits/SolidResourcesSwift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "MobileSolidCompatModel",
            dependencies: [],
            path: "Sources/MobileSolidCompatModel"
        ),
        .target(
            name: "MobileSolidCompatImportProbe",
            dependencies: [
                "MobileSolidCompatModel",
                .product(name: "SolidAuthSwiftTools", package: "SolidAuthSwift"),
                .product(name: "SolidResourcesSwift", package: "SolidResourcesSwift"),
            ],
            path: "Sources/MobileSolidCompatImportProbe"
        ),
        .target(
            name: "MobileSolidCompatUI",
            dependencies: [
                "MobileSolidCompatModel",
                .product(name: "SolidAuthSwiftUI", package: "SolidAuthSwift"),
            ],
            path: "Sources/MobileSolidCompatUI"
        ),
        .testTarget(
            name: "MobileSolidCompatModelTests",
            dependencies: ["MobileSolidCompatModel"],
            path: "Tests/MobileSolidCompatModelTests"
        ),
    ]
)
