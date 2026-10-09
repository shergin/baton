@_spi(Generated) import Baton
import BatonInspector
import BatonSpec
import Foundation
import Testing

/// The cases harvested from Relay's own store tests into `spec/relay/`: each
/// commits the payload Relay's test normalized and compares the store with
/// the records Relay's test expected, keyed as Baton keys them. The manifest
/// has the main manifest's format; `spec/relay/README.md` says what the
/// harvest kept and why the rest dropped out.
extension Spec {
    static let relayManifest: Manifest = {
        do {
            return try JSONDecoder().decode(Manifest.self, from: data("relay/manifest.json"))
        } catch {
            fatalError("Spec: relay/manifest.json does not read: \(error)")
        }
    }()

    /// The cases and scripts where Baton parts from Relay, by name, each
    /// with a line saying how. They wait for the owner's decision; until
    /// then each runs as a known issue, which fails once it passes.
    static let relayDivergences: [String: String] = {
        do {
            return try JSONDecoder().decode([String: String].self, from: data("relay/divergences.json"))
        } catch {
            fatalError("Spec: relay/divergences.json does not read: \(error)")
        }
    }()
}

struct RelayCase: Sendable, CustomTestStringConvertible {
    let entry: Manifest.Case

    var testDescription: String { entry.name }

    static let all = Spec.relayManifest.cases.map(RelayCase.init(entry:))
}

struct RelayScript: Sendable, CustomTestStringConvertible {
    let path: String

    var testDescription: String { path }

    static let all = Spec.relayManifest.scripts.map(RelayScript.init(path:))
}

struct RelayError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
@Suite("Relay's store tests")
struct RelayTests {
    @Test("a payload Relay's normalizer tests commit leaves the records Relay's test expects", arguments: RelayCase.all)
    func aPayloadLeavesTheRecordsRelayExpects(_ relay: RelayCase) throws {
        try divergent(relay.entry.name) {
            let store = Store()
            store.log = nil
            for response in relay.entry.responses {
                try commit(relay.entry.operation, relay.entry.variables, response, into: store)
            }
            expectDump(store, relay.entry.records)
        }
    }

    @Test("payloads Relay's normalizer tests commit in a row leave, after each, the records Relay's test expects", arguments: RelayScript.all)
    func payloadsInARowLeaveTheRecordsRelayExpects(_ relay: RelayScript) throws {
        let script = try Manifest.Script.load(relay.path)
        try divergent(relay.path) {
            let store = Store()
            store.log = nil
            for (index, step) in script.steps.enumerated() {
                guard case .payload(let operation, let response) = step.action else {
                    Issue.record("\(relay.path): step \(index + 1) is a `\(step.action.kind)`, which the Relay scripts do not take")
                    return
                }
                try commit(operation.name, operation.variables, response, into: store)
                if let records = step.records {
                    expectDump(store, records, context: "after step \(index + 1): ")
                }
            }
        }
    }

    @Test("every operation the Relay cases name has its document under spec/relay/documents, equal to the text the compiler generated")
    func theDocumentsAgreeWithTheGeneratedText() throws {
        let bless = ProcessInfo.processInfo.environment["BATON_BLESS"] != nil
        for entry in Spec.relayManifest.cases {
            let operation = try Self.operation(entry.operation)
            let text = (operation.text ?? "") + "\n"
            let url = Spec.directory.appendingPathComponent(entry.document)
            if bless {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
                continue
            }
            guard let written = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("\(entry.document) is missing; run the tests with BATON_BLESS=1 to write it")
                continue
            }
            #expect(written == text, "\(entry.document) differs from the text the compiler generated")
        }
    }

    // MARK: Helpers

    /// Runs a case's body, as a known issue when it is a recorded divergence.
    func divergent(_ name: String, _ body: () throws -> Void) throws {
        guard let divergence = Spec.relayDivergences[name] else {
            try body()
            return
        }
        withKnownIssue(Comment(rawValue: divergence)) {
            try body()
        }
    }

    static func operation(_ name: String) throws -> any Baton.Operation.Type {
        guard let operation = RelayDocuments.operations[name] else {
            throw RelayError(description: "no generated operation is named \(name)")
        }
        return operation
    }

    /// Commits a response as a payload: the ingest takes what the response
    /// holds, and a field it does not hold stays as the store had it.
    func commit(_ name: String, _ variables: [String: Manifest.Value], _ response: String, into store: Store) throws {
        let operation = try Self.operation(name)
        let plan = operation.plan.resolve(Variables(variables.mapValues(\.variable)), in: store.keys)
        store.commit(try Ingest.normalize(Spec.data(response), plan: plan, rootKey: Store.rootKey))
    }

    /// Compares the store with a dump under `spec/`, by its path. The dump
    /// is Relay's, so `BATON_BLESS=1` never writes it.
    func expectDump(_ store: Store, _ path: String, context: String = "", sourceLocation: SourceLocation = #_sourceLocation) {
        let text = StoreExport.text(of: store)
        let expected = String(decoding: Spec.data(path), as: UTF8.self)
        guard text != expected else { return }
        let actualLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let line = zip(actualLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actualLines.count, expectedLines.count)
        let store = line < actualLines.count ? String(actualLines[line]) : "<end>"
        let dump = line < expectedLines.count ? String(expectedLines[line]) : "<end>"
        Issue.record("\(context)the store differs from \(path) at line \(line + 1):\n  store: \(store)\n  relay: \(dump)", sourceLocation: sourceLocation)
    }
}

extension Manifest.Value {
    /// The value as an operation variable.
    var variable: Variable {
        switch self {
        case .null: .null
        case .bool(let bool): .bool(bool)
        case .int(let int): .int(int)
        case .double(let double): .double(double)
        case .string(let string): .string(string)
        case .list(let items): .list(items.map(\.variable))
        case .object(let members): .object(members.mapValues(\.variable))
        }
    }
}
