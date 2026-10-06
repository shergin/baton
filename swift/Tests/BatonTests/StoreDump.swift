import Baton
import BatonInspector
import BatonSpec
import Foundation
import Testing

/// The comparison of a store with the dumps `spec/` freezes, in the format
/// `StoreExport` writes.
enum StoreDump {
    /// Compares the store with the dump beside a response in `spec/`
    /// (`rickandmorty/characters-page-1.store.json`); with `BATON_BLESS=1`
    /// in the environment, writes the dump instead.
    @MainActor static func expectMatches(_ store: Store, _ name: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let url = Spec.directory.appendingPathComponent(name + ".store.json")
        let text = StoreExport.text(of: store)
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
