import Baton
import BatonSpec
import Foundation
import Testing

/// The store as `spec/` freezes it: every record by key, each a map from
/// storage key to value, a link written as Relay writes it (`{"__ref": key}`,
/// `{"__refs": [key]}`), the record's type as `__typename`, field errors under
/// `__errors`, and a deleted record as null. Keys are sorted and each record
/// is one line, so a change to identity or layout is a reviewable diff.
enum StoreDump {
    @MainActor static func text(of store: Store) -> String {
        let records = store.recordsByKey.sorted { $0.key < $1.key }
        let lines = records.map { key, record in
            "  " + quote(key) + ": " + (record.deleted ? "null" : object(record, in: store))
        }
        return "{\n" + lines.joined(separator: ",\n") + "\n}\n"
    }

    @MainActor private static func object(_ record: Record, in store: Store) -> String {
        var fields: [(String, String)] = [("__typename", quote(record.type.name))]
        var errors: [(String, String)] = []
        for (slot, value, error) in record.storedSlots {
            fields.append((store.storageKey(of: slot), json(value)))
            if let error {
                errors.append((store.storageKey(of: slot), "{\"message\": " + quote(error.message) + ", \"path\": " + quote(error.path) + "}"))
            }
        }
        if !errors.isEmpty {
            fields.append(("__errors", "{" + errors.sorted { $0.0 < $1.0 }.map { quote($0.0) + ": " + $0.1 }.joined(separator: ", ") + "}"))
        }
        return "{" + fields.sorted { $0.0 < $1.0 }.map { quote($0.0) + ": " + $0.1 }.joined(separator: ", ") + "}"
    }

    @MainActor private static func json(_ value: Value) -> String {
        switch value {
        case .missing, .null: "null"
        case .bool(let bool): bool ? "true" : "false"
        case .int(let int): String(int)
        case .double(let double): String(double)
        case .string(let string): quote(string)
        case .ref(let record): "{\"__ref\": " + quote(record.key) + "}"
        case .refs(let records): "{\"__refs\": [" + records.map { $0.map { quote($0.key) } ?? "null" }.joined(separator: ", ") + "]}"
        case .list(let items): "[" + items.map(json).joined(separator: ", ") + "]"
        }
    }

    private static func quote(_ text: String) -> String {
        var output = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case _ where scalar.value < 0x20: output += String(format: "\\u%04x", scalar.value)
            default: output.unicodeScalars.append(scalar)
            }
        }
        return output + "\""
    }

    /// Compares the store with the dump beside a response in `spec/`
    /// (`rickandmorty/characters-page-1.store.json`); with `BATON_BLESS=1`
    /// in the environment, writes the dump instead.
    @MainActor static func expectMatches(_ store: Store, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = Spec.directory.appendingPathComponent(name + ".store.json")
        let text = text(of: store)
        if ProcessInfo.processInfo.environment["BATON_BLESS"] != nil {
            try? Data(text.utf8).write(to: url)
            return
        }
        guard let expected = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("\(url.lastPathComponent) is missing; run the tests with BATON_BLESS=1 to write it", sourceLocation: sourceLocation)
            return
        }
        guard text != expected else { return }
        let actualLines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let expectedLines = expected.split(separator: "\n", omittingEmptySubsequences: false)
        let line = zip(actualLines, expectedLines).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(actualLines.count, expectedLines.count)
        let store = line < actualLines.count ? String(actualLines[line]) : "<end>"
        let dump = line < expectedLines.count ? String(expectedLines[line]) : "<end>"
        Issue.record("the store differs from \(url.lastPathComponent) at line \(line + 1):\n  store: \(store)\n  dump:  \(dump)", sourceLocation: sourceLocation)
    }
}
