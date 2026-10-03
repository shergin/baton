// swift-tools-version: 6.1
import PackageDescription

// The Apollo iOS comparison for BENCHMARKS.md: the same fixture response and
// the same operation, through Apollo's parser, normalizer and cache.
let package = Package(
    name: "ApolloComparison",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apollographql/apollo-ios", exact: "2.4.0"),
        .package(path: "./RickAndMortyAPI"),
    ],
    targets: [
        .executableTarget(
            name: "ApolloComparison",
            dependencies: [
                .product(name: "Apollo", package: "apollo-ios"),
                .product(name: "ApolloAPI", package: "apollo-ios"),
                .product(name: "RickAndMortyAPI", package: "RickAndMortyAPI"),
            ]
        ),
    ]
)
