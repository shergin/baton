import Baton
import BatonSpec
import Foundation
import Observation
import Testing

/// A response of the tokenizer fixture that is not well formed, and what
/// ingesting it must give: an `IngestError`, or the leaves listed.
struct MalformedResponse: Sendable, CustomTestStringConvertible {
    let file: String
    let error: Bool
    let leaves: [Leaf]

    var testDescription: String { file }

    static let all: [MalformedResponse] = {
        let manifest = try! JSONSerialization.jsonObject(with: Spec.data("tokenizer/malformed.json")) as! [[String: Any]]
        return manifest.map { entry in
            let leaves = ((entry["leaves"] as? [String: Any]) ?? [:])
                .sorted { $0.key < $1.key }
                .map { Leaf(path: $0.key, value: LeafValue(json: $0.value)) }
            return MalformedResponse(file: entry["response"] as! String, error: entry["error"] != nil, leaves: leaves)
        }
    }()
}

extension LeafValue {
    /// A value as a manifest writes it in JSON.
    init(json: Any) {
        switch json {
        case is NSNull: self = .null
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): self = .bool(number.boolValue)
        case let number as NSNumber where CFNumberIsFloatType(number): self = .double(number.doubleValue)
        case let number as NSNumber: self = .int(number.intValue)
        case let string as String: self = .string(string)
        case let items as [Any]: self = .list(items.map(LeafValue.init(json:)))
        default: self = .string("\(json)")
        }
    }
}

@MainActor
@Suite("The tokenizer", .timeLimit(.minutes(1)))
struct TokenizerTests {
    let plan = TestTokenizerQuery.plan.resolve(TestTokenizerQuery().variables)

    @Test("the printed document is the one in spec/tokenizer")
    func theDocumentIsTheSpecs() {
        let text = String(decoding: Spec.data("tokenizer/tokenizer.graphql"), as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#") }
            .joined(separator: "\n")
        #expect(text.trimmingCharacters(in: .whitespacesAndNewlines) == TestTokenizerQuery.text)
    }

    @Test("a response that is not well formed fails with an ingest error or reads as the manifest says", arguments: MalformedResponse.all)
    func malformed(_ response: MalformedResponse) throws {
        let data = Spec.data("tokenizer/" + response.file)
        if response.error {
            #expect(throws: IngestError.self) { try Ingest.normalize(data, plan: plan) }
            return
        }
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(data, plan: plan))
        let leaves = Oracle.leaves(of: store.root, in: store, plan: plan)
        for expected in response.leaves {
            #expect(leaves.first { $0.path == expected.path } == expected)
        }
    }

    @Test("a custom scalar keeps the text of its token: a string's contents, and any other token as the server wrote it")
    func customScalarsAreText() throws {
        let store = Store()
        store.reportMissing = nil
        store.commit(try Ingest.normalize(Spec.data("tokenizer/custom-tokens.json"), plan: plan))
        let data = TestTokenizerQuery.Data(anchor: Anchor(record: store.root, variables: .none, store: store))
        #expect(data.tokenizer?.json == #"{"b":1, "a":[true,null]}"#)
        #expect(data.tokenizer?.jsons == ["text", "12345678901234567890", "1.50", "true", #"{"k":"v"}"#, "[1,2]", "-0.0"])
    }

    @Test("a list of scalars that changes in one element is stored again, and an equal one notifies nothing", arguments: [
        ("tokenizer.strings", LeafValue.list([.string("plain"), .null, .string("été"), .string("changed"), .null])),
        ("tokenizer.counts", LeafValue.list([.int(0), .int(1), .null])),
        ("tokenizer.ratios", LeafValue.list([.double(1000), .double(0.5)])),
        ("tokenizer.flags", LeafValue.list([.bool(true), .null, .bool(true)])),
    ])
    func scalarListChanges(_ path: String, _ value: LeafValue) throws {
        let store = Store()
        store.reportMissing = nil
        let response = Spec.data("tokenizer/response.json")
        store.commit(try Ingest.normalize(response, plan: plan))
        let tokenizer = try #require(store.existing("Tokenizer:t1"))
        let field = String(path.split(separator: ".").last!)
        let slot = Registry.slot(tokenizer.type, field)
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        func observe() { withObservationTracking { _ = tokenizer.read(slot) } onChange: { counter.fired += 1 } }

        observe()
        store.commit(try Ingest.normalize(response, plan: plan))
        #expect(counter.fired == 0, "the same list is no change")

        store.commit(try Ingest.normalize(try Oracle.replacing(path, with: value, in: response), plan: plan))
        #expect(counter.fired == 1)
        #expect(Oracle.leaves(of: store.root, in: store, plan: plan).first { $0.path == path }?.value == value)
    }

    @Test("an entity whose id is a custom scalar given as a number is one record, whether its id comes before a link or after it")
    func numericCustomIDs() throws {
        let query = Registry.type("Query")
        let user = Registry.type("TestNumericUser")
        func entity(_ fields: [PlanField]) -> Selection { Selection(type: user, hasID: true, fields: fields) }
        let id = PlanField.scalar("id", key: .fixed(Registry.slot(user, "id")), kind: .custom, list: false)
        let plan = Plan(root: Selection(type: query, hasID: false, fields: [
            .linked("user", key: .fixed(Registry.slot(query, "user")), plural: false, selection: entity([
                id,
                .linked("friend", key: .fixed(Registry.slot(user, "friend")), plural: false, selection: entity([id])),
            ])),
        ])).resolve(.none)
        let first = try Ingest.normalize(Data(#"{"data":{"user":{"id":42,"friend":{"id":7}}}}"#.utf8), plan: plan)
        let last = try Ingest.normalize(Data(#"{"data":{"user":{"friend":{"id":7},"id":42}}}"#.utf8), plan: plan)
        #expect(first.recordKeys.contains("TestNumericUser:42"))
        #expect(Set(last.recordKeys) == Set(first.recordKeys))
    }
}
