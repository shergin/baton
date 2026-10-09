import Foundation

/// The availability check: whether the store holds an operation's data, and
/// the lookups it binds on the way. Memory answers first; when it cannot
/// and the store has an image, the same walk runs again with the image at
/// hand, and what it reads becomes part of the store. See `spec/runtime.md`,
/// section 5.
extension Store {
    /// Whether every field of the selection is present, starting at `record`.
    /// A missing root link with a lookup is satisfied by the cached entity,
    /// and the link is written so later reads are direct.
    ///
    /// Memory answers first. When it cannot and the store has an image, the
    /// same walk runs again with the image at hand, and what it reads becomes
    /// part of the store: this is how a launch renders its first body from
    /// the last one's data.
    package func check(_ selection: ResolvedSelection, at record: Record? = nil) -> Answer {
        adoptConstants()
        // What the image's responses taught in earlier launches, before the
        // walk resolves a variant for a type the plan did not list.
        if let persistence {
            for (type, condition) in persistence.takeMemberships() { Membership.learn(Registry.type(type), of: Registry.type(condition)) }
        }
        let record = record ?? root
        // What the walk writes, a lookup's link bound, a link repaired, a
        // cell filled from the image, is one local batch, notified once the
        // walk is over: nothing observes a walk in progress. The walk's state
        // is passed, never captured: a variable a closure captures is boxed,
        // and every `inout` pass of it then pays a dynamic exclusivity check.
        var walk = Walk(batch: Batch(.local))
        defer { _ = finish(walk.batch) }
        if available(selection, at: record, from: nil, &walk) { return walk.met ? .image : .memory }
        guard let persistence else { return .miss }
        let found = persistence.reading(&walk) { disk, walk in
            available(selection, at: record, from: disk, &walk)
        }
        return found ? .image : .miss
    }

    /// The state of one availability walk: the local batch of what it
    /// writes, and whether the walk in memory met a record or a root field
    /// the image filled.
    struct Walk {
        var batch: Batch
        var met = false
    }

    /// Whether every deferred part of a selection the check found is whole,
    /// in memory or, through the check, in the image. The check passes over
    /// deferred fields, while a record read from the image holds every cell
    /// of its row, a deferred fragment's link among them, with nothing
    /// behind it: such a field is cleared, so its fragment reads absent
    /// rather than empty, unless the initial part reads the same field and
    /// its data is there. Either way the answer is false, so the operation
    /// fetches.
    func deferredPartsHold(_ selection: ResolvedSelection, at record: Record? = nil) -> Bool {
        var whole = true
        var batch = Batch(.local)
        deferredParts(selection, at: record ?? root, &whole, &batch)
        _ = finish(batch)
        return whole
    }

    private func deferredParts(_ selection: ResolvedSelection, at record: Record, _ whole: inout Bool, _ batch: inout Batch) {
        let fields = selection.variant(for: record.type).read
        for field in fields {
            let value = record.peek(field.slot)
            guard case .linked(let child, _, _, _) = field.kind else {
                if field.deferred != nil, case .missing = value { whole = false }
                continue
            }
            var targets: [Record] = []
            switch value {
            case .ref(let target) where !target.deleted: targets = [target]
            case .refs(let list): targets = list.compactMap { $0 }.filter { !$0.deleted }
            case .missing: if field.deferred != nil { whole = false }
            default: break
            }
            guard field.deferred != nil else {
                for target in targets { deferredParts(child, at: target, &whole, &batch) }
                continue
            }
            if targets.contains(where: { check(child, at: $0) == .miss }) {
                // A slot that a field outside the deferred part reads as
                // well keeps its value: it is that field's data.
                if !fields.contains(where: { $0.deferred == nil && $0.slot == field.slot }) {
                    set(record, field.slot, .missing, &batch)
                }
                whole = false
            }
        }
    }

    /// Where the availability check found the selection's data.
    package enum Answer: Sendable {
        /// In memory, every record of it put there by a response.
        case memory
        /// With the image's help: read from it now, or by an earlier check.
        case image
        /// Not all of it, in memory or in the image.
        case miss
    }

    /// The availability walk: whether every field of the selection is
    /// present at `record`. Without a disk it reads memory as it stands; with
    /// one, a record that lacks a field reads its row first, a link to a
    /// record the collector swept is pointed at the live record of that key,
    /// and a connection's client record is walked while it holds nothing.
    private func available(_ selection: ResolvedSelection, at record: Record, from disk: Disk?, _ walk: inout Walk) -> Bool {
        available(selection.variant(for: record.type), at: record, from: disk, &walk)
    }

    /// The walk over one record's fields the check waits for, then the
    /// connections' client links. The lists are the variant's, read in
    /// place, so neither a list nor a field is retained per record.
    private func available(_ variant: ResolvedVariant, at record: Record, from disk: Disk?, _ walk: inout Walk) -> Bool {
        let fields = variant.waits
        if disk == nil {
            if record.hydrated {
                walk.met = true
            } else if record === root, !hydratedRootSlots.isEmpty, readsHydratedRootSlot(fields) {
                walk.met = true
            }
        }
        for index in fields.indices {
            let slot = fields[index].slot
            if let disk, case .missing = record.peek(slot) { hydrate(record, slot, from: disk, &walk.batch) }
            switch fields[index].kind {
            case .scalar(let kind, let list):
                if !record.holds(slot, kind, list: list) { return false }
            case .linked(let child, let plural, let lookupKey, _):
                switch record.peek(slot) {
                case .missing:
                    guard !plural, let lookupKey, let target = resolve(lookupKey, disk, &walk.batch) else { return false }
                    guard available(child, at: target, from: disk, &walk) else { return false }
                    set(record, slot, .ref(target), &walk.batch)
                case .null:
                    break
                case .ref(let found):
                    var target = found
                    if let disk {
                        target = live(found, disk, &walk.batch)
                        if target !== found { set(record, slot, .ref(target), &walk.batch) }
                    }
                    if !target.deleted, !available(child, at: target, from: disk, &walk) { return false }
                case .refs(var targets):
                    if let disk {
                        var moved = false
                        for position in targets.indices {
                            guard let found = targets[position] else { continue }
                            let target = live(found, disk, &walk.batch)
                            if target !== found {
                                targets[position] = target
                                moved = true
                            }
                        }
                        if moved { set(record, slot, .refs(targets), &walk.batch) }
                    }
                    for case let target? in targets where !target.deleted && !available(child, at: target, from: disk, &walk) { return false }
                default:
                    return false
                }
            }
        }
        // A client field is never waited for, but the image holds what a
        // payload wrote: it is hydrated here, and the records behind a client
        // link brought back, without a miss for what no server sends.
        if let disk {
            for field in variant.payloadFields {
                let slot = field.slot
                if case .missing = record.peek(slot) { hydrate(record, slot, from: disk, &walk.batch) }
                guard case .linked(let child, _, _, _) = field.kind else { continue }
                switch record.peek(slot) {
                case .ref(let found):
                    let target = live(found, disk, &walk.batch)
                    if target !== found { set(record, slot, .ref(target), &walk.batch) }
                    if !target.deleted { _ = available(child, at: target, from: disk, &walk) }
                case .refs(var targets):
                    var moved = false
                    for position in targets.indices {
                        guard let found = targets[position] else { continue }
                        let target = live(found, disk, &walk.batch)
                        if target !== found {
                            targets[position] = target
                            moved = true
                        }
                    }
                    if moved { set(record, slot, .refs(targets), &walk.batch) }
                    for case let target? in targets where !target.deleted { _ = available(child, at: target, from: disk, &walk) }
                default:
                    break
                }
            }
        }
        // Lenses read a connection through its client record, which the walk
        // above does not pass. A merge always fills it, so one that holds
        // nothing, swept or never filled, is not in memory: the image may
        // hold it, or have been told to forget it. With the image at hand it
        // is walked, so its merged pages come back with it, and one the
        // image has no row for stays a miss. The root's link is a cell of
        // its own in the image, read here, since the walk above hydrates the
        // root a waited field at a time and waits for no client link.
        for link in variant.clientLinks {
            if let disk, case .missing = record.peek(link.slot) { hydrate(record, link.slot, from: disk, &walk.batch) }
            guard case .linked(let child, _, _, _) = link.kind, case .ref(let found) = record.peek(link.slot), found.swept || found.isEmpty else { continue }
            guard let disk else { return false }
            let merged = live(found, disk, &walk.batch)
            if merged !== found { set(record, link.slot, .ref(merged), &walk.batch) }
            if !merged.deleted, !available(child, at: merged, from: disk, &walk) { return false }
        }
        return true
    }

    /// Whether the walk reads one of the root's fields the image filled:
    /// taken once, before the walk, so the records below pay nothing for it.
    private func readsHydratedRootSlot(_ waits: [ResolvedField]) -> Bool {
        for index in waits.indices where hydratedRootSlots.contains(waits[index].slot.index) { return true }
        return false
    }

    /// A link's target as the store and the image know it together: the live
    /// record of the key when the collector swept the one the link holds,
    /// and, for a record that holds nothing yet, its row, so that whether it
    /// was deleted is known before the walk decides to enter it.
    private func live(_ found: Record, _ disk: Disk, _ batch: inout Batch) -> Record {
        let record = found.swept ? target(key: found.key, type: found.type, entity: found.isEntity) : found
        if !record.hydrated, record.isEmpty, record !== root, record !== mutationRoot, record !== subscriptionRoot {
            _ = hydrate(record, from: disk, &batch)
        }
        return record
    }

    /// Reads from the image what a record lacks: the root's field, or the
    /// record's row, once.
    func hydrate(_ record: Record, _ slot: Slot, from disk: Disk, _ batch: inout Batch) {
        if record === root {
            _ = hydrateRoot(slot, from: disk, &batch)
        } else if !record.hydrated, record !== mutationRoot, record !== subscriptionRoot {
            _ = hydrate(record, from: disk, &batch)
        }
    }
}
