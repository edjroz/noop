// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DefraSync",
    platforms: [.macOS(.v13)],
    products: [.library(name: "DefraSync", targets: ["DefraSync"])],
    dependencies: [
        .package(path: "../WhoopStore"),
    ],
    targets: [
        .target(
            name: "DefraSync",
            dependencies: ["WhoopStore"]
        ),
        .testTarget(
            name: "DefraSyncTests",
            dependencies: ["DefraSync", "WhoopStore"]
        ),
    ]
)
