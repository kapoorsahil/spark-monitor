// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SparkMonitor",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "SparkMonitor", path: "Sources/SparkMonitor")
    ]
)
