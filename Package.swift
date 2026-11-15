// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "CopyText",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CopyText",
            path: "Sources/CopyText",
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Vision"),
            ]
        )
    ]
)
