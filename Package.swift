// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "MeeABridgeCore", platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "MeeABridgeCore", targets: ["MeeABridgeCore"])],
    targets: [.target(name: "MeeABridgeCore"), .testTarget(name: "MeeABridgeCoreTests", dependencies: ["MeeABridgeCore"])])
