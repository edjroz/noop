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
        // DefraEmbed.xcframework is produced by Tools/defradb-embed/build.sh (Phase 2) from
        // the Go module under defradb-embed/. It's gitignored — anyone cloning the repo must
        // run the build script (or rely on the Xcode pre-build phase wired into project.yml)
        // before `swift build` can resolve this target. The framework's own module.modulemap
        // exposes the C ABI as `import DefraEmbed`.
        .binaryTarget(
            name: "DefraEmbedFFI",
            path: "DefraEmbed.xcframework"
        ),
        .target(
            name: "DefraSync",
            dependencies: ["WhoopStore", "DefraEmbedFFI"]
        ),
        .testTarget(
            name: "DefraSyncTests",
            dependencies: ["DefraSync", "WhoopStore"]
        ),
    ]
)
