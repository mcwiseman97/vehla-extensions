// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AntinoteDockWidget",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AntinoteDockWidget", type: .dynamic, targets: ["AntinoteDockWidget"]),
    ],
    dependencies: [
        .package(path: "../../sdk/swift"),
    ],
    targets: [
        .target(
            name: "AntinoteDockWidget",
            dependencies: [
                .product(name: "VehlaDockWidgetSDK", package: "swift"),
            ],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .testTarget(
            name: "AntinoteDockWidgetTests",
            dependencies: ["AntinoteDockWidget"],
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
    ]
)
