@_spi(Generated) import Baton
import BatonInspector
import BatonSpec
import Foundation
import Testing

/// The cases harvested from Relay's own store tests into `spec/relay/`: each
/// commits the payload Relay's test normalized and compares the store with
/// the records Relay's test expected, keyed as Baton keys them. The manifest
/// has the main manifest's format; `spec/relay/README.md` says what each
/// status means and what the harvest kept.
extension Spec {
    static let relayManifest: Manifest = {
        do {
            return try JSONDecoder().decode(Manifest.self, from: data("relay/manifest.json"))
        } catch {
            fatalError("Spec: relay/manifest.json does not read: \(error)")
        }
    }()

    /// The status of every case the manifest lists, by the case's name.
    static let relayCaseMarks: [String: RelayMarks] = {
        struct Listing: Decodable { let cases: [RelayMarks] }
        do {
            let listing = try JSONDecoder().decode(Listing.self, from: data("relay/manifest.json"))
            return Dictionary(uniqueKeysWithValues: listing.cases.map { ($0.name, $0) })
        } catch {
            fatalError("Spec: relay/manifest.json does not read: \(error)")
        }
    }()
}

/// What the harvest says of a case or a script: a status when Baton is not
/// held to Relay's result, and why. Relay's tests are measured against, not
/// obeyed: a case with a status runs as a known issue, which fails once it
/// passes, except an unsupported feature's, which is left out of the runs.
struct RelayMarks: Decodable, Sendable {
    let name: String
    let status: String?
    let note: String?

    var isRun: Bool { status != "unsupported-feature" }
}

struct RelayCase: Sendable, CustomTestStringConvertible {
    let entry: Manifest.Case

    var testDescription: String { entry.name }

    var marks: RelayMarks? { Spec.relayCaseMarks[entry.name] }

    static let all = Spec.relayManifest.cases.map(RelayCase.init(entry:)).filter { $0.marks?.isRun ?? true }
}

struct RelayScript: Sendable, CustomTestStringConvertible {
    let path: String
    let marks: RelayMarks

    var testDescription: String { path }

    static let all: [RelayScript] = Spec.relayManifest.scripts.compactMap { path in
        guard let marks = try? JSONDecoder().decode(RelayMarks.self, from: Spec.data(path)) else {
            fatalError("Spec: \(path) does not read")
        }
        return marks.isRun ? RelayScript(path: path, marks: marks) : nil
    }
}

struct RelayError: Error, CustomStringConvertible {
    let description: String
}

@MainActor
@Suite("Relay's store tests")
struct RelayTests {
    @Test("a payload Relay's tests commit leaves the records Relay's test expects", arguments: RelayCase.all)
    func aPayloadLeavesTheRecordsRelayExpects(_ relay: RelayCase) throws {
        try measured(relay.marks) {
            let store = Store()
            store.log = nil
            for response in relay.entry.responses {
                try commit(relay.entry.operation, relay.entry.variables, response, into: store)
            }
            expectDump(store, relay.entry.records)
        }
    }

    @Test("payloads Relay's tests commit in a row leave the records Relay's test expects, a check after them gives Relay's answer, and a lens reads what Relay's reader reads", arguments: RelayScript.all)
    func payloadsInARowLeaveWhatRelayExpects(_ relay: RelayScript) throws {
        let script = try Manifest.Script.load(relay.path)
        try measured(relay.marks) {
            let store = Store()
            store.log = nil
            for (index, step) in script.steps.enumerated() {
                switch step.action {
                case .payload(let operation, let response):
                    try commit(operation.name, operation.variables, response, into: store)
                case .check(let operation):
                    let answer = store.check(try Self.operation(operation.name).plan.resolve(Variables(operation.variables.mapValues(\.variable)), in: store.keys))
                    if let expected = step.answer {
                        #expect("\(answer)" == expected.rawValue, "step \(index + 1): the check answers \(answer) where Relay's answer is \(expected.rawValue)")
                    }
                default:
                    Issue.record("\(relay.path): step \(index + 1) is a `\(step.action.kind)`, which the Relay scripts do not take")
                    return
                }
                if let records = step.records {
                    expectDump(store, records, context: "after step \(index + 1): ")
                }
                if !step.reads.isEmpty {
                    try expectReads(step.reads, in: store, script: relay.path, context: "after step \(index + 1): ")
                }
            }
        }
    }

    @Test("every operation the Relay cases and scripts compile has its document under spec/relay/documents, equal to the text the compiler generated")
    func theDocumentsAgreeWithTheGeneratedText() throws {
        let bless = ProcessInfo.processInfo.environment["BATON_BLESS"] != nil
        var names = Set(Spec.relayManifest.cases.map(\.operation))
        for path in Spec.relayManifest.scripts {
            for step in try Manifest.Script.load(path).steps {
                switch step.action {
                case .payload(let operation, _), .check(let operation): names.insert(operation.name)
                default: break
                }
            }
        }
        for name in names.sorted() {
            guard let operation = RelayDocuments.operations[name] else { continue }
            let text = (operation.text ?? "") + "\n"
            let document = "relay/documents/\(name).graphql"
            let url = Spec.directory.appendingPathComponent(document)
            if bless {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
                continue
            }
            guard let written = try? String(contentsOf: url, encoding: .utf8) else {
                Issue.record("\(document) is missing; run the tests with BATON_BLESS=1 to write it")
                continue
            }
            #expect(written == text, "\(document) differs from the text the compiler generated")
        }
    }

    // MARK: Helpers

    /// Compares what the generated lens reads at each row with the row: its
    /// value, its `@catch` result, or what it throws. The row at the empty
    /// path is the operation's own outcome, and without one the operation
    /// reads.
    func expectReads(_ rows: [Manifest.ScriptRead], in store: Store, script: String, context: String) throws {
        guard let name = rows.first?.operation else {
            Issue.record("\(context)a read names no operation")
            return
        }
        let variables = Variables((rows.first?.variables ?? [:]).mapValues(\.variable))
        let anchor = Anchor(record: store.root, variables: variables, store: store)
        let outcome = Self.outcome(try Self.operation(name), anchor)
        let expected = rows.first { $0.path.isEmpty }?.throws
        #expect(outcome == expected, "\(context)the operation \(outcome.map { "fails with \($0)" } ?? "reads") where Relay's \(expected.map { "fails with \($0)" } ?? "reads")")
        for row in rows where !row.path.isEmpty {
            guard let read = RelayReads.readers[script] else {
                Issue.record("\(context)no generated reads for \(script)")
                return
            }
            let actual: RelayRead
            do {
                guard let value = try read(anchor, row.path) else {
                    Issue.record("\(context)no generated read of \(row.path)")
                    continue
                }
                actual = .value(value)
            } catch is RequiredFieldError {
                actual = .threw("requiredField")
            } catch is FieldErrors {
                actual = .threw("fieldErrors")
            } catch {
                actual = .threw("\(error)")
            }
            let wanted: RelayRead = row.throws.map(RelayRead.threw) ?? .value(row.result ?? row.value)
            #expect(actual.isSame(as: wanted), "\(context)the lens reads \(row.path) as \(actual) where Relay reads \(wanted)")
        }
    }

    /// What an operation's own read fails with: a `@required` field that
    /// bubbled to its root, or field errors under `@throwOnFieldError`.
    static func outcome<Op: Baton.Operation>(_ operation: Op.Type, _ anchor: Anchor) -> String? {
        if !Op.Data.satisfied(anchor) { return "requiredField" }
        if Op.throwsOnFieldError, !Op.Data.fieldErrors(anchor).isEmpty { return "fieldErrors" }
        return nil
    }

    /// Runs a case's body, as a known issue when the harvest gives it a
    /// status: its result is then ignored until it passes.
    func measured(_ marks: RelayMarks?, _ body: () throws -> Void) throws {
        guard let marks, let status = marks.status else {
            try body()
            return
        }
        withKnownIssue(Comment(rawValue: "\(status): \(marks.note ?? "")")) {
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

/// What a read gave: a value in the manifest's spelling, or the kind of
/// error it threw.
enum RelayRead: CustomStringConvertible {
    case value(Manifest.Value)
    case threw(String)

    var description: String {
        switch self {
        case .value(let value): "\(value)"
        case .threw(let kind): "a thrown \(kind)"
        }
    }

    func isSame(as other: RelayRead) -> Bool {
        switch (self, other) {
        case (.value(let value), .value(let expected)): value.isSameJSON(as: expected)
        case (.threw(let kind), .threw(let expected)): kind == expected
        default: false
        }
    }
}

/// The reads the translator generates for each script, in `RelayReads.swift`.
enum RelayReads {}

extension Manifest.Value {
    /// Whether two values are the same JSON: a number is one number however
    /// it is spelled, and an object's members compare by name.
    func isSameJSON(as other: Manifest.Value) -> Bool {
        switch (self, other) {
        case (.int(let int), .double(let double)), (.double(let double), .int(let int)):
            return Double(int) == double
        case (.list(let items), .list(let others)):
            return items.count == others.count && zip(items, others).allSatisfy { $0.isSameJSON(as: $1) }
        case (.object(let members), .object(let others)):
            return members.count == others.count && members.allSatisfy { key, value in others[key].map(value.isSameJSON) ?? false }
        default:
            return self == other
        }
    }

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
