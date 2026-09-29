// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Micky",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "Micky",
            path: "Sources/Micky"
        )
    ]
)
