// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "ResearchDockWidget", platforms: [.macOS(.v14)],
    products: [.library(name: "ResearchDockWidget", type: .dynamic, targets: ["ResearchDockWidget"])],
    dependencies: [.package(path: "../../sdk/swift")],
    targets: [
        .target(name: "ResearchDockWidget", dependencies: [.product(name: "VehlaDockWidgetSDK", package: "swift")]),
        .testTarget(name: "ResearchDockWidgetTests", dependencies: ["ResearchDockWidget"])
    ]
)
