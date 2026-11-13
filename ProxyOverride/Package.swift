// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "ProxyOverride",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(name: "ProxyOverride", path: "Sources/ProxyOverride")
    ],
    swiftLanguageModes: [.v5]
)
