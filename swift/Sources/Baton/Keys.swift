import Synchronization

/// The storage keys a session renders from its variables, numbered by the
/// store that renders them: one per id looked up and per cursor paged
/// past. The process numbers what the build names (`Registry`); a store
/// numbers what its session produces, apart from the build's dense slots,
/// and forgets it at its end, so nothing a session produces is kept in a
/// table of the process. A text has one slot in a store: a rendering whose
/// text the build names as a constant takes the constant's slot, and a
/// constant the build names after the store rendered its text is adopted,
/// the store's number becoming the constant's twin.
/// Locked, because a plan's variant for a type it did not list is resolved
/// where the response is read, off the main actor.
package final class Keys: Sendable {
    private struct Table {
        /// The number of each text numbered on the type.
        var numbers: [String: Int32] = [:]
        /// The text of each number.
        var texts: [String] = []
        /// The dense slot of each number whose text the build named later.
        var twins: [Int32: Int32] = [:]
    }

    private struct State {
        /// By `TypeID.raw`.
        var tables: [Table] = []
        /// How many of the build's keys on each type the store has compared
        /// its own numbers with.
        var reconciled: [Int] = []
        /// The twins made and not yet given to the store, which copies the
        /// records' values across.
        var adoptions: [(rendered: Slot, dense: Slot)] = []
    }

    private let state = Mutex(State())
    /// The build's total the store last reconciled against, read without
    /// the lock at every resolution.
    private let seen = Atomic<Int>(0)
    /// Whether twins wait for the store, read without the lock.
    let hasAdoptions = Atomic<Bool>(false)

    package init() {}

    /// The slot of a rendered key on a type: the build's, when the process
    /// has a constant of the text; otherwise the store's number, `~n`.
    func slot(_ type: TypeID, _ text: String) -> Slot {
        if let dense = Registry.denseIndex(type, text) { return Slot(type: type, index: dense) }
        return state.withLock { state in
            let table = Int(type.raw)
            if table >= state.tables.count { state.tables.append(contentsOf: repeatElement(Table(), count: table + 1 - state.tables.count)) }
            if let number = state.tables[table].numbers[text] { return Slot(type: type, index: ~number) }
            let number = Int32(state.tables[table].texts.count)
            state.tables[table].texts.append(text)
            state.tables[table].numbers[text] = number
            return Slot(type: type, index: ~number)
        }
    }

    /// The text of a slot: the build's for a dense one, the store's for one
    /// numbered here; empty for a number the store has forgotten.
    func text(of slot: Slot) -> String {
        if slot.index >= 0 { return Registry.storageKey(slot) }
        return state.withLock { state in
            let table = Int(slot.type.raw)
            let number = Int(~slot.index)
            guard table < state.tables.count, number < state.tables[table].texts.count else { return "" }
            return state.tables[table].texts[number]
        }
    }

    /// Compares the store's numbers with the keys the build has named since
    /// the last time: a text the store numbered that the build now names as
    /// a constant gets the constant's slot as its twin, for the store to
    /// adopt. Called at every resolution; free when the build named nothing
    /// new.
    func reconcile() {
        if Registry.denseTotal.load(ordering: .relaxed) == seen.load(ordering: .relaxed) { return }
        state.withLock { state in
            let (fresh, total) = Registry.denseKeys(since: &state.reconciled)
            seen.store(total, ordering: .relaxed)
            for (type, text, index) in fresh {
                let table = Int(type.raw)
                guard table < state.tables.count, let number = state.tables[table].numbers[text] else { continue }
                state.tables[table].twins[number] = index
                state.adoptions.append((Slot(type: type, index: ~number), Slot(type: type, index: index)))
            }
            if !state.adoptions.isEmpty { hasAdoptions.store(true, ordering: .relaxed) }
        }
    }

    /// The twins made since the store last took them.
    func takeAdoptions() -> [(rendered: Slot, dense: Slot)] {
        state.withLock { state in
            hasAdoptions.store(false, ordering: .relaxed)
            let adoptions = state.adoptions
            state.adoptions.removeAll()
            return adoptions
        }
    }

    /// How many keys the store has numbered on the type; for tests and
    /// benchmarks.
    package func count(on type: TypeID) -> Int {
        state.withLock { state in
            let table = Int(type.raw)
            return table < state.tables.count ? state.tables[table].texts.count : 0
        }
    }

    /// Forgets every key: the session ended, and the process keeps no text
    /// it rendered.
    func clear() {
        state.withLock { $0.tables.removeAll() }
    }
}
