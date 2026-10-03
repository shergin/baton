import Baton
import BatonSpec
import Foundation
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
        let leaves = Oracle.leaves(of: store.root, plan: plan)
        for expected in response.leaves {
            #expect(leaves.first { $0.path == expected.path } == expected)
        }
    }
}
