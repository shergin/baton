// swift-tools-version: 6.2
import PackageDescription

// Two modules of one app, the second spreading a fragment the first
// declares: `Shared` is the base, `Screens` its dependent. Their generated
// sources are not built by the plugin but by `scripts/check-bases.sh`, which
// runs the compiler for each module in turn, the base first, as the command
// line and Bazel do, and writes them under each target's `Generated/`.
let package = Package(
    name: "Bases",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(name: "Baton", path: "../../.."),
    ],
    targets: [
        .target(
            name: "Shared",
            dependencies: [.product(name: "Baton", package: "Baton")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "Screens",
            dependencies: ["Shared", .product(name: "Baton", package: "Baton")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ScreensTests",
            dependencies: [
                "Screens",
                "Shared",
                .product(name: "Baton", package: "Baton"),
                .product(name: "BatonTesting", package: "Baton"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
