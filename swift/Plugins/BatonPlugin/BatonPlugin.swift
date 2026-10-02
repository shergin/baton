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
            sources: target.sourceFiles(withSuffix: ".swift").map(\.url),
            packageDirectory: context.package.directoryURL,
            workDirectory: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "batonc").url
        )
    }

    /// Builds the single `batonc generate` command for a set of sources.
    static func commands(targetName: String, sources: [URL], packageDirectory: URL, workDirectory: URL, tool: URL) throws -> [Command] {
        let configuration = try Configuration.load(from: packageDirectory)
        let schema = packageDirectory.appending(path: configuration.schema)
        let outputDirectory = workDirectory.appending(path: "Generated")

        var inputs: [URL] = [schema]
        var arguments = ["generate", "--schema", schema.path(percentEncoded: false)]
        var outputs: [URL] = []
        for source in sources {
            inputs.append(source)
            arguments.append(source.path(percentEncoded: false))
            guard declaresGraphQL(source) else { continue }
            let output = outputDirectory.appending(path: source.deletingPathExtension().lastPathComponent + ".baton.swift")
            outputs.append(output)
            arguments += ["--emit", "\(source.path(percentEncoded: false))=\(output.path(percentEncoded: false))"]
        }
        guard !outputs.isEmpty else { return [] }

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

    static func load(from directory: URL) throws -> Configuration {
        let url = directory.appending(path: "baton.json")
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
            sources: target.inputFiles.filter { $0.url.pathExtension == "swift" }.map(\.url),
            packageDirectory: context.xcodeProject.directoryURL,
            workDirectory: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "batonc").url
        )
    }
}
#endif
