import Baton
import SwiftUI

/// A view over an environment's store, for a debug menu: the store's counts,
/// its records by type, searchable by key, each with its slots, values and
/// field errors, and an export in the dump format `spec/` freezes. It reads
/// and never writes; a product of its own, so a release build need not link
/// it.
@MainActor
public struct StoreInspector: View {
    private let environment: Baton.Environment
    @State private var search = ""
    @State private var refreshed = 0

    public init(_ environment: Baton.Environment) {
        self.environment = environment
    }

    public var body: some View {
        NavigationStack {
            List {
                Section("Store") {
                    LabeledContent("Records", value: String(store.count))
                    LabeledContent("Roots", value: String(store.rootCount))
                    LabeledContent("Optimistic layers", value: String(store.optimisticLayers.count))
                    LabeledContent("Collections", value: String(store.collections))
                }
                ForEach(groups, id: \.type) { group in
                    Section("\(group.type) (\(group.records.count))") {
                        ForEach(group.records, id: \.key) { record in
                            NavigationLink(record.key) { RecordInspector(record: record, store: store) }
                        }
                    }
                }
            }
            .id(refreshed)
            .searchable(text: $search, prompt: "Key")
            .navigationTitle("Store")
            .toolbar {
                Button("Refresh", systemImage: "arrow.clockwise") { refreshed += 1 }
                ShareLink(item: StoreExport.text(of: store), preview: SharePreview("Store dump"))
            }
        }
    }

    private var store: Store { environment.store }

    /// The records by type name, each group's records by key, those the
    /// search matches.
    private var groups: [(type: String, records: [Record])] {
        var byType: [String: [Record]] = [:]
        for record in store.recordsByKey.values where search.isEmpty || record.key.localizedCaseInsensitiveContains(search) {
            byType[record.type.name, default: []].append(record)
        }
        return byType.keys.sorted().map { type in
            (type: type, records: byType[type]!.sorted { $0.key < $1.key })
        }
    }
}

/// One record: its type, its key, whether it is deleted, and its slots by
/// storage key with their values and field errors.
@MainActor
struct RecordInspector: View {
    let record: Record
    let store: Store

    var body: some View {
        List {
            Section {
                LabeledContent("Type", value: record.type.name)
                LabeledContent("Key", value: record.key)
                if record.deleted { Text("Deleted") }
            }
            Section("Slots") {
                ForEach(slots, id: \.key) { slot in
                    VStack(alignment: .leading) {
                        LabeledContent(slot.key, value: slot.value)
                        if let error = slot.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .navigationTitle(record.key)
    }

    private var slots: [(key: String, value: String, error: String?)] {
        record.storedSlots
            .map { slot, value, error in
                (key: store.storageKey(of: slot), value: StoreExport.json(value), error: error.map { "\($0.message) at \($0.path)" })
            }
            .sorted { $0.key < $1.key }
    }
}
