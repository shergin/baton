import Synchronization

/// The storage keys a session renders from its variables, numbered by the
/// store that renders them: one per id looked up and per cursor paged
/// past. The process numbers what the build names (`Registry`); a store
/// numbers what its session produces, apart from the build's dense slots,
/// frees it with its collector and forgets it at its end, so nothing a
/// session produces is kept in a table of the process. A text has one slot
/// in a store: a rendering whose text the build names as a constant takes
/// the constant's slot, and a constant the build names after the store
/// rendered its text is adopted, the store's number becoming the constant's
/// twin. A number is used again for another text only once nothing can
/// name it: no resolution or scope that took it is alive, and no optimistic
/// layer or row waiting for the image carries it.
/// Locked, because a plan's variant for a type it did not list is resolved
/// where the response is read, off the main actor.
package final class Keys: Sendable {
    /// What a resolution or a scope holds of the store's keys: the numbers
    /// it took, kept while it lives, so that none is used again for another
    /// text while something that could name it is alive.
    final class Hold: Sendable {
        let keys: Keys
        fileprivate let taken = Mutex<[Slot]>([])

        fileprivate init(_ keys: Keys) { self.keys = keys }

        deinit { keys.unpin(taken.withLock { $0 }) }
    }

    private struct Table {
        /// The number of each text numbered on the type.
        var numbers: [String: Int32] = [:]
        /// The text of each number; nil for a number that is free.
        var texts: [String?] = []
        /// How many holds have each number.
        var pins: [Int] = []
        /// The dense slot of each number whose text the build named later.
        /// A twin is never freed: the build's constant lives as long as the
        /// process.
        var twins: [Int32: Int32] = [:]
        /// The numbers free to use again, the lowest last.
        var free: [Int32] = []
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

    /// A hold for a resolution or a scope to take numbers with.
    func hold() -> Hold { Hold(self) }

    /// The slot of a rendered key on a type, taken for `hold`: the build's,
    /// when the process has a constant of the text; otherwise the store's
    /// number, `~n`, a free one used again or a new one.
    func slot(_ type: TypeID, _ text: String, for hold: Hold) -> Slot {
        if let dense = Registry.denseIndex(type, text) { return Slot(type: type, index: dense) }
        let slot = state.withLock { state -> Slot in
            let table = Int(type.raw)
            if table >= state.tables.count { state.tables.append(contentsOf: repeatElement(Table(), count: table + 1 - state.tables.count)) }
            let number: Int32
            if let known = state.tables[table].numbers[text] {
                number = known
            } else if let reused = state.tables[table].free.popLast() {
                number = reused
                state.tables[table].texts[Int(number)] = text
                state.tables[table].numbers[text] = number
            } else {
                number = Int32(state.tables[table].texts.count)
                state.tables[table].texts.append(text)
                state.tables[table].pins.append(0)
                state.tables[table].numbers[text] = number
            }
            state.tables[table].pins[Int(number)] += 1
            return Slot(type: type, index: ~number)
        }
        hold.taken.withLock { $0.append(slot) }
        return slot
    }

    private func unpin(_ slots: [Slot]) {
        if slots.isEmpty { return }
        state.withLock { state in
            for slot in slots {
                let table = Int(slot.type.raw)
                let number = Int(~slot.index)
                guard table < state.tables.count, number < state.tables[table].pins.count else { continue }
                state.tables[table].pins[number] -= 1
            }
        }
    }

    /// The text of a slot: the build's for a dense one, the store's for one
    /// numbered here; empty for a number the store has freed.
    func text(of slot: Slot) -> String {
        if slot.index >= 0 { return Registry.storageKey(slot) }
        return state.withLock { state in
            let table = Int(slot.type.raw)
            let number = Int(~slot.index)
            guard table < state.tables.count, number < state.tables[table].texts.count else { return "" }
            return state.tables[table].texts[number] ?? ""
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

    /// Frees every number nothing can name any more: not taken by a live
    /// resolution or scope, not among `kept`, the optimistic layers' and
    /// the waiting rows', and not a twin. Their texts go, the numbers are
    /// used again lowest first, and each table shrinks to its highest
    /// number in use. Returns the freed slots, for the store to drop the
    /// records' entries under them and tell the image.
    func free(butKeeping kept: Set<Slot>) -> [Slot] {
        state.withLock { state in
            var freed: [Slot] = []
            for table in state.tables.indices {
                let type = TypeID(raw: Int32(table))
                for number in state.tables[table].texts.indices {
                    let slot = Slot(type: type, index: ~Int32(number))
                    guard let text = state.tables[table].texts[number], state.tables[table].pins[number] == 0,
                          state.tables[table].twins[Int32(number)] == nil, !kept.contains(slot)
                    else { continue }
                    state.tables[table].texts[number] = nil
                    state.tables[table].numbers.removeValue(forKey: text)
                    freed.append(slot)
                }
                var count = state.tables[table].texts.count
                while count > 0, state.tables[table].texts[count - 1] == nil { count -= 1 }
                state.tables[table].texts.removeLast(state.tables[table].texts.count - count)
                state.tables[table].pins.removeLast(state.tables[table].pins.count - count)
                state.tables[table].free = (0..<count).reversed().compactMap { state.tables[table].texts[$0] == nil ? Int32($0) : nil }
            }
            return freed
        }
    }

    /// How many keys the store numbers on the type now; for tests and
    /// benchmarks.
    package func count(on type: TypeID) -> Int {
        state.withLock { state in
            let table = Int(type.raw)
            return table < state.tables.count ? state.tables[table].numbers.count : 0
        }
    }

    /// Forgets every key: the session ended, and the process keeps no text
    /// it rendered.
    func clear() {
        state.withLock { $0.tables.removeAll() }
    }
}
