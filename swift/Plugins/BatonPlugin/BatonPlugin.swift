import Foundation
import PackagePlugin

/// Runs `batonc generate` for a target. One output per source file that
/// declares GraphQL, so the command can be a `buildCommand` with declared
/// outputs and the build system reruns it only when an input changes.
/// Each output is named by its source's path in the target.
@main
struct BatonPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        guard let target = target as? SourceModuleTarget else { return [] }
        return try Self.commands(
            targetName: target.name,
            sources: target.sourceFiles.filter { Self.sourceExtensions.contains($0.url.pathExtension) }.map(\.url),
            root: target.directoryURL,
            configurationDirectories: [target.directoryURL, context.package.directoryURL],
            workDirectory: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "batonc").url
        )
    }

    /// The files the compiler reads: Swift sources and GraphQL documents.
    static let sourceExtensions = ["swift", "graphql", "gql"]

    /// Builds the single `batonc generate` command for a set of sources.
    /// `baton.json` is read from the first directory that has one: the target's
    /// own, then the package root, so one package can hold targets against
    /// different schemas.
    static func commands(targetName: String, sources: [URL], root: URL, configurationDirectories: [URL], workDirectory: URL, tool: URL) throws -> [Command] {
        guard let configurationFile = configurationDirectories
            .map({ $0.appending(path: "baton.json") })
            .first(where: { FileManager.default.fileExists(atPath: $0.path(percentEncoded: false)) })
        else {
            Diagnostics.warning("Baton: no baton.json for \(targetName); skipping")
            return []
        }
        let configuration = try Configuration.load(at: configurationFile)
        let schema = configurationFile.deletingLastPathComponent().appending(path: configuration.schema)
        let outputDirectory = workDirectory.appending(path: "Generated")
        let shared = outputDirectory.appending(path: "Baton.baton.swift")

        var inputs: [URL] = [schema, configurationFile]
        var arguments = ["generate", "--config", configurationFile.path(percentEncoded: false), "--shared", shared.path(percentEncoded: false)]
        var outputs: [URL] = []
        for source in sources {
            inputs.append(source)
            arguments.append(source.path(percentEncoded: false))
            guard source.pathExtension != "swift" || declaresGraphQL(source) else { continue }
            let output = outputDirectory.appending(path: outputName(source, root: root))
            // SwiftPM refuses two producers of one file without naming the
            // source, so the one whose output is the shared file is named here.
            guard output != shared else {
                let path = source.path(percentEncoded: false)
                Diagnostics.error("Baton: `\(path)` would write the shared `\(shared.lastPathComponent)`; rename it", file: path, line: nil)
                return []
            }
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

    /// The output a source writes: its path relative to `root`, each
    /// directory separator an underscore, with `.baton.swift` in place of a
    /// `.swift` extension and after any other, so `Thing.swift` and
    /// `Thing.graphql`, or two files of one name in two directories, write
    /// two outputs. `batonc generate --out` names its files by the same rule.
    static func outputName(_ source: URL, root: URL) -> String {
        let path = source.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        let relative = path.starts(with: base) ? Array(path.dropFirst(base.count)) : [source.lastPathComponent]
        let joined = relative.joined(separator: "_")
        let stem = joined.hasSuffix(".swift") ? String(joined.dropLast(".swift".count)) : joined
        return stem + ".baton.swift"
    }

    /// Whether a file may declare GraphQL: it names a marker, bare or
    /// qualified by the module. A superset of what the compiler's scanner
    /// accepts, which also wants a literal after the parenthesis, so no file
    /// with a document is left out; a file without one gets a header only.
    private static func declaresGraphQL(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        return ["@Fragment", "@Query", "@Mutation", "@Subscription", "@Baton."].contains { text.contains($0) }
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
            sources: target.inputFiles.filter { Self.sourceExtensions.contains($0.url.pathExtension) }.map(\.url),
            root: context.xcodeProject.directoryURL,
            configurationDirectories: [context.xcodeProject.directoryURL],
            workDirectory: context.pluginWorkDirectoryURL,
            tool: try context.tool(named: "batonc").url
        )
    }
}
#endif
