import Foundation

/// An incremental response as it arrives: the parts the first one announced,
/// by id, and each later part turned into the objects it delivers, each at the
/// record its path names with the selection it fills, and into the parts the
/// server says it could not deliver. Where an object goes is read from the
/// store, here; the objects themselves are normalized off the main actor.
/// Relay's format, the June 2023 one and the 2024 one, as `Ingest.incremental`
/// reads them.
@MainActor
struct Delivery {
    private let store: Store
    private let resolved: ResolvedSelection
    private var announced: [String: Ingest.IncrementalPart.Pending] = [:]

    init(store: Store, resolved: ResolvedSelection) {
        self.store = store
        self.resolved = resolved
    }

    /// Notes the parts a part announces, the 2024 format's `pending`.
    mutating func announce(_ pending: [Ingest.IncrementalPart.Pending]) {
        for part in pending { announced[part.id] = part }
    }

    /// The objects a part delivers: each by its own path and label, or by the
    /// id of an announced part, at the record the path names. Below the
    /// announced path an item carries the rest of an object the part selects,
    /// by the object's own selection.
    func objects(of part: Ingest.IncrementalPart) -> [Ingest.ObjectPart] {
        var objects: [Ingest.ObjectPart] = []
        for item in part.items {
            let base = item.path ?? item.id.flatMap { announced[$0]?.path }
            let label = item.label ?? item.id.flatMap { announced[$0]?.label }
            guard let base, let label else { continue }
            let path = base + (item.subPath ?? [])
            guard let (record, selection) = store.walk(path, resolved) else { continue }
            let plan = item.subPath?.isEmpty == false ? selection : selection.deferred(label)
            guard let plan else { continue }
            objects.append(Ingest.ObjectPart(data: item.data, plan: plan, key: record.key, type: record.type, entity: record.isEntity, path: path, errors: item.errors))
        }
        return objects
    }

    /// The announced parts a part says the server could not deliver, each
    /// as the errors on the fields it would have filled.
    func failures(of part: Ingest.IncrementalPart) -> [Ingest.FailedPart] {
        var failures: [Ingest.FailedPart] = []
        for completion in part.completed where !completion.errors.isEmpty {
            guard let pending = announced[completion.id], let label = pending.label,
                  let (record, selection) = store.walk(pending.path, resolved),
                  let deferred = selection.deferred(label)
            else { continue }
            failures.append(Ingest.failed(deferred, key: record.key, type: record.type, entity: record.isEntity, at: pending.path, errors: completion.errors))
        }
        return failures
    }
}
