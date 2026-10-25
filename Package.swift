// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Genie",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Genie", path: "Sources/Genie")
    ]
)
