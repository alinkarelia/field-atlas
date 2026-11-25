// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "FieldCore", platforms: [.iOS(.v17), .macOS(.v13)], products: [.library(name: "FieldCore", targets: ["FieldCore"])], targets: [.target(name: "FieldCore"), .testTarget(name: "FieldCoreTests", dependencies: ["FieldCore"])])
