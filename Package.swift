// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "Baton",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Baton", targets: ["Baton"]),
        .plugin(name: "BatonPlugin", targets: ["BatonPlugin"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "602.0.0"),
    ],
    targets: [
        .target(
            name: "Baton",
            dependencies: ["BatonMacros"],
            path: "swift/Sources/Baton",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .macro(
            name: "BatonMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "swift/Sources/BatonMacros"
        ),
        .binaryTarget(
            name: "batonc",
            path: "compiler/dist/batonc.artifactbundle"
        ),
        .plugin(
            name: "BatonPlugin",
            capability: .buildTool(),
            dependencies: ["batonc"],
            path: "swift/Plugins/BatonPlugin"
        ),
        // The fixtures under `spec/`, read in place by the tests and the
        // benchmarks.
        .target(
            name: "BatonSpec",
            path: "swift/Spec",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "BatonTests",
            dependencies: ["Baton", "BatonSpec"],
            path: "swift/Tests/BatonTests",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
        .testTarget(
            name: "BatonMacrosTests",
            dependencies: [
                "BatonMacros",
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
            ],
            path: "swift/Tests/BatonMacrosTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "RickAndMorty",
            dependencies: ["Baton"],
            path: "examples/RickAndMorty",
            exclude: ["baton.json"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
        .executableTarget(
            name: "GitHubTriage",
            dependencies: ["Baton"],
            path: "examples/GitHubTriage",
            exclude: ["schema.docs.graphql", "baton.json"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
        .executableTarget(
            name: "BatonBenchmarks",
            dependencies: ["Baton", "BatonSpec"],
            path: "swift/Benchmarks",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
    ]
)
