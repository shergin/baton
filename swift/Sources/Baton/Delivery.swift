import Foundation

/// An incremental response as it arrives: the parts the first one announced,
/// by id, and each later part turned into the objects it delivers, each at the
/// record its path names with the selection it fills, or into the streamed
/// list it is an item of, and into the parts the server says it could not
/// deliver. Where an object goes is read from the store, here; the objects
/// themselves are normalized off the main actor. Relay's format, the June
/// 2023 one and the 2024 one, as `Ingest.incremental` reads them.
@MainActor
struct Delivery {
    private let store: Store
    private let resolved: ResolvedSelection
    private var announced: [String: Ingest.IncrementalPart.Pending] = [:]
    /// Each streamed list as this response left it, by its parent record and
    /// slot: the list as the part that carried it was committed, then the
    /// list after each item landed. An item that finds the list changed by
    /// anything else, or finds a list this response never wrote, is stale,
    /// as Relay's executor holds, and is dropped.
    private var streams: [Stream: ContiguousArray<Record?>] = [:]

    private struct Stream: Hashable {
        let parent: ObjectIdentifier
        let slot: Slot
    }

    init(store: Store, resolved: ResolvedSelection) {
        self.store = store
        self.resolved = resolved
    }

    /// Notes the parts a part announces, the 2024 format's `pending`.
    mutating func announce(_ pending: [Ingest.IncrementalPart.Pending]) {
        for part in pending { announced[part.id] = part }
    }

    /// The objects a part delivers: each by its own path and label, or by the
    /// id of an announced part. A deferred part's object lands at the record
    /// the path names, or below a sub-path with the rest of an object the
    /// part selects, by the object's own selection. A streamed list's items
    /// land in the list at the parent the path names, at the index the path
    /// ends in, or after the last item the stream left when it names none.
    mutating func objects(of part: Ingest.IncrementalPart) -> [Ingest.ObjectPart] {
        var objects: [Ingest.ObjectPart] = []
        for item in part.items {
            let base = item.path ?? item.id.flatMap { announced[$0]?.path }
            let label = item.label ?? item.id.flatMap { announced[$0]?.label }
            guard let base, let label else {
                dropped(item.path ?? [])
                continue
            }
            if let items = item.items {
                objects.append(contentsOf: streamed(items, at: base, errors: item.errors))
                continue
            }
            if case .index? = base.last {
                // Relay's shape: one item, its path ending in its index.
                objects.append(contentsOf: streamed([item.data], at: base, errors: item.errors))
                continue
            }
            let path = base + (item.subPath ?? [])
            guard let place = store.locate(path, resolved) else {
                dropped(path)
                continue
            }
            let plan = item.subPath?.isEmpty == false ? place.selection : place.selection.deferred(label)
            guard let plan else {
                dropped(path)
                continue
            }
            var object = Ingest.ObjectPart(data: item.data, plan: plan, key: place.record.key, type: place.record.type, entity: place.record.isEntity, path: path, errors: item.errors)
            object.remerge = remerge(place.connection, place.paged)
            objects.append(object)
        }
        return objects
    }

    /// The items of a streamed list as objects, each placed at its index in
    /// the list at the parent record the path names. The path ends in the
    /// first item's index, or in the field, when the items follow the last
    /// one the stream left. The path names the list; the part's label is
    /// not read again, since the plan marks the field that streams.
    private mutating func streamed(_ items: [Data], at base: [Ingest.PathSegment], errors: [Ingest.ResponseError]) -> [Ingest.ObjectPart] {
        var listPath = base
        var start: Int?
        if case .index(let index)? = listPath.last {
            listPath.removeLast()
            start = index
        }
        guard case .name(let name)? = listPath.last, let place = store.locate(Array(listPath.dropLast()), resolved) else {
            dropped(base)
            return []
        }
        let variant = place.selection.variant(for: place.record.type)
        guard let position = variant.field(named: name) else {
            dropped(base)
            return []
        }
        let field = variant.fields[position]
        guard field.streams, case .linked(let child, plural: true, _, _) = field.kind, case .refs = place.record.peek(field.slot) else {
            dropped(base)
            return []
        }
        guard let left = streams[Stream(parent: ObjectIdentifier(place.record), slot: field.slot)] else {
            dropped(base)
            return []
        }
        let first = start ?? left.count
        let remerge = remerge(place.connection, place.paged)
        return items.enumerated().map { offset, data in
            var object = Ingest.ObjectPart(data: data, plan: child, key: place.record.key, type: place.record.type, entity: place.record.isEntity, path: listPath + [.index(first + offset)], errors: errors)
            object.placement = .item(storageKey: field.storageKey, slot: field.slot, index: first + offset)
            object.remerge = remerge
            return object
        }
    }

    /// The merge an object landing on a connection's page, or on a paged
    /// list's, asks for.
    private func remerge(_ connection: (key: String, resolved: ResolvedConnection)?, _ paged: (key: String, resolved: ResolvedPaged)?) -> Ingest.ObjectPart.Remerge? {
        if let connection {
            return .connection(key: connection.key, slots: connection.resolved.slots, mode: connection.resolved.mode)
        }
        if let paged, let number = paged.resolved.page {
            return .paged(key: paged.key, paged: paged.resolved, number: number)
        }
        return nil
    }

    /// Whether a streamed item still fits: the list it is an item of is as
    /// the stream left it. A list another commit replaced or edited
    /// meanwhile is that commit's; the item is stale, dropped and logged.
    func fits(_ object: Ingest.ObjectPart) -> Bool {
        guard case .item(_, let slot, _) = object.placement else { return true }
        guard let parent = store.existing(object.key), !parent.deleted, case .refs(let current) = parent.peek(slot) else {
            dropped(object.path)
            return false
        }
        guard let left = streams[Stream(parent: ObjectIdentifier(parent), slot: slot)], Delivery.same(current, left) else {
            dropped(object.path)
            return false
        }
        return true
    }

    /// Notes every streamed list a committed change set of this response
    /// wrote, as the commit left it: the lists a part carried, and the one
    /// an item was placed in.
    mutating func committed(_ changes: ChangeSet) {
        for (record, slot) in changes.streams {
            guard let parent = store.existing(changes.recordKeys[Int(record)]), case .refs(let now) = parent.peek(slot) else { continue }
            streams[Stream(parent: ObjectIdentifier(parent), slot: slot)] = now
        }
    }

    private static func same(_ first: ContiguousArray<Record?>, _ second: ContiguousArray<Record?>) -> Bool {
        guard first.count == second.count else { return false }
        for index in first.indices where first[index] !== second[index] { return false }
        return true
    }

    /// The announced parts a part says the server could not deliver, each
    /// as the errors on the fields it would have filled: a deferred part's
    /// fields, or the streamed list field whose stream broke off.
    func failures(of part: Ingest.IncrementalPart) -> [Ingest.FailedPart] {
        var failures: [Ingest.FailedPart] = []
        for completion in part.completed where !completion.errors.isEmpty {
            guard let pending = announced[completion.id], let label = pending.label else {
                dropped(announced[completion.id]?.path ?? [])
                continue
            }
            if let place = store.locate(pending.path, resolved), let deferred = place.selection.deferred(label) {
                failures.append(Ingest.failed(deferred, key: place.record.key, type: place.record.type, entity: place.record.isEntity, at: pending.path, errors: completion.errors))
                continue
            }
            if case .name(let name)? = pending.path.last, let place = store.locate(Array(pending.path.dropLast()), resolved),
               let position = place.selection.variant(for: place.record.type).field(named: name),
               case let field = place.selection.variant(for: place.record.type).fields[position], field.streams {
                failures.append(Ingest.failedStream(field, key: place.record.key, type: place.record.type, entity: place.record.isEntity, at: pending.path, errors: completion.errors))
                continue
            }
            dropped(pending.path)
        }
        return failures
    }

    /// A part that reaches no record, no deferred selection or no streamed
    /// list, or an item whose list changed under it, is dropped and logged:
    /// the response named a place the plan or the store does not have,
    /// which is the server's and the build's disagreement to see.
    private func dropped(_ path: [Ingest.PathSegment]) {
        store.log?(.partDropped(path: Ingest.render(path)))
    }
}
