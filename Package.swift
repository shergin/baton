// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

/// The release whose compiler bundle a package that depends on Baton
/// downloads, and the bundle's checksum. The release workflow writes both
/// into the release commit; empty until a release publishes a bundle.
let compilerRelease = (version: "0.12.0", checksum: "635f2b10ab4e1231186833a55985169c28da8a1aaf5005c5001b66f4fa19dae2")

/// The compiler the build plugin runs: the one `scripts/build-compiler.sh`
/// built into this checkout, or else the bundle the release published.
/// SwiftPM caches this choice by the manifest's text and environment, not
/// by what is on disk, so `BATON_COMPILER=local` or `=release` settles it
/// for a checkout evaluated before its compiler was built.
let localCompiler = "compiler/dist/batonc.artifactbundle"
let usesLocalCompiler = switch Context.environment["BATON_COMPILER"] {
case "local": true
case "release": false
default: compilerRelease.version.isEmpty
    || FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + localCompiler + "/info.json")
}
let compiler: Target = usesLocalCompiler
    ? .binaryTarget(name: "batonc", path: localCompiler)
    : .binaryTarget(
        name: "batonc",
        url: "https://github.com/shergin/baton/releases/download/v\(compilerRelease.version)/batonc.artifactbundle.zip",
        checksum: compilerRelease.checksum
    )

let package = Package(
    name: "Baton",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        .library(name: "Baton", targets: ["Baton"]),
        // The recorded and the silent transports, for an app's tests and
        // previews; nothing in it ships in the app.
        .library(name: "BatonTesting", targets: ["BatonTesting"]),
        // A view over a store for a debug menu, and the store's export in
        // the dump format `spec/` freezes; a product of its own, so a
        // release build need not link it.
        .library(name: "BatonInspector", targets: ["BatonInspector"]),
        .plugin(name: "BatonPlugin", targets: ["BatonPlugin"]),
    ],
    dependencies: [
        // From the floor's toolchain, Swift 6.2, to the newest release, so
        // an app resolves the swift-syntax that matches its compiler. When
        // the range moves is recorded in
        // `docs/decisions/swift-syntax-spans-the-floor-to-the-newest.md`.
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "602.0.0"..<"605.0.0"),
    ],
    targets: [
        .target(
            name: "Baton",
            dependencies: ["BatonMacros"],
            path: "swift/Sources/Baton",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "BatonTesting",
            dependencies: ["Baton"],
            path: "swift/Sources/BatonTesting",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "BatonInspector",
            dependencies: ["Baton"],
            path: "swift/Sources/BatonInspector",
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
        compiler,
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
            dependencies: ["Baton", "BatonTesting", "BatonInspector", "BatonSpec", "Exchange"],
            path: "swift/Tests/BatonTests",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
        // Relay's own store tests, harvested into `spec/relay/` by
        // `scripts/relay-harvest/` and compiled against Relay's test schema.
        .testTarget(
            name: "BatonRelayTests",
            dependencies: ["Baton", "BatonInspector", "BatonSpec"],
            path: "swift/Tests/BatonRelayTests",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
        // The emitter's goldens, compiled as an app compiles them with the
        // Xcode template's default of main-actor isolation: generated code
        // states its isolation, so it builds under either default.
        .testTarget(
            name: "BatonGoldenTests",
            dependencies: ["Baton"],
            path: "compiler/src/tests/goldens",
            swiftSettings: [.swiftLanguageMode(.v6), .defaultIsolation(MainActor.self)]
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
        // The exchange of `docs/recipes/exchange.md`: a wrapper over the
        // transport's one verb an app copies, compiled here so the GitHub
        // sample sends through it and the tests prove it.
        .target(
            name: "Exchange",
            dependencies: ["Baton"],
            path: "examples/Exchange",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "GitHubTriage",
            dependencies: ["Baton", "Exchange"],
            path: "examples/GitHubTriage",
            exclude: ["schema.docs.graphql", "baton.json"],
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
        .executableTarget(
            name: "BatonBenchmarks",
            dependencies: ["Baton", "BatonTesting", "BatonSpec"],
            path: "swift/Benchmarks",
            swiftSettings: [.swiftLanguageMode(.v6)],
            plugins: ["BatonPlugin"]
        ),
    ]
)
