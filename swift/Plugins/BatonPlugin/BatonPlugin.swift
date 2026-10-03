import Foundation
import PackagePlugin

/// Runs `batonc generate` for a target. One output per source file that
/// declares GraphQL, so the command can be a `buildCommand` with declared
/// outputs and the build system reruns it only when an input changes.
@main
struct BatonPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        return try Self.commands(
            targetName: target.name,
            sources: target.sourceFiles.filter { ["swift", "graphql"].contains($0.url.pathExtension) }.map(\.url),
            packageDirectory: context.package.directoryURL,
            workDirectory: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "batonc").url
        )
    }

    /// Builds the single `batonc generate` command for a set of sources.
    static func commands(targetName: String, sources: [URL], packageDirectory: URL, workDirectory: URL, tool: URL) throws -> [Command] {
        let configurationFile = packageDirectory.appending(path: "baton.json")
        let configuration = try Configuration.load(at: configurationFile)
        let schema = packageDirectory.appending(path: configuration.schema)
        let outputDirectory = workDirectory.appending(path: "Generated")
        let shared = outputDirectory.appending(path: "Baton.baton.swift")

        var inputs: [URL] = [schema, configurationFile]
        var arguments = ["generate", "--config", configurationFile.path(percentEncoded: false), "--shared", shared.path(percentEncoded: false)]
        var outputs: [URL] = []
        for source in sources {
            inputs.append(source)
            // Documents in .graphql files compile too; only Swift files get a sibling output.
            arguments.append(source.path(percentEncoded: false))
            guard source.pathExtension == "swift", declaresGraphQL(source) else { continue }
            let output = outputDirectory.appending(path: source.deletingPathExtension().lastPathComponent + ".baton.swift")
            outputs.append(output)
            arguments += ["--emit", "\(source.path(percentEncoded: false))=\(output.path(percentEncoded: false))"]
        }
        guard !outputs.isEmpty else { return [] }
        outputs.append(shared)

        return [
            .buildCommand(
                displayName: "Baton: compile GraphQL in \(targetName)",
                executable: tool,
                arguments: arguments,
                inputFiles: inputs,
                outputFiles: outputs
            ),
        ]
    }

    /// The same rule the compiler applies: a marker attribute followed by a parenthesis.
    private static func declaresGraphQL(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return ["@Fragment(", "@Query(", "@Mutation(", "@Subscription("].contains { text.contains($0) }
    }
}

struct Configuration: Decodable {
    var schema: String

    static func load(at url: URL) throws -> Configuration {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Configuration.self, from: data)
    }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

/// The same command for targets of an Xcode project; `baton.json` is read from
/// the project directory.
extension BatonPlugin: XcodeBuildToolPlugin {
    func createBuildCommands(context: XcodePluginContext, target: XcodeTarget) throws -> [Command] {
        try Self.commands(
            targetName: target.displayName,
            sources: target.inputFiles.filter { ["swift", "graphql"].contains($0.url.pathExtension) }.map(\.url),
            packageDirectory: context.xcodeProject.directoryURL,
            workDirectory: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "batonc").url
        )
    }
}
#endif
