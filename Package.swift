// swift-tools-version: 6.2
import CompilerPluginSupport
import Foundation
import PackageDescription

/// The release whose compiler bundle a package that depends on Baton
/// downloads, and the bundle's checksum. The release workflow writes both
/// into the release commit; empty until a release publishes a bundle.
let compilerRelease = (version: "", checksum: "")

/// The compiler the build plugin runs: the one `scripts/build-compiler.sh`
/// built into this checkout, or else the bundle the release published.
let localCompiler = "compiler/dist/batonc.artifactbundle"
let compiler: Target = compilerRelease.version.isEmpty
    || FileManager.default.fileExists(atPath: Context.packageDirectory + "/" + localCompiler + "/info.json")
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
            dependencies: ["Baton", "BatonSpec"],
            path: "swift/Tests/BatonTests",
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
