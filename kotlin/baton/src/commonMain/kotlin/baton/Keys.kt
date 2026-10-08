package baton

import kotlin.concurrent.atomics.AtomicReference
import kotlin.concurrent.atomics.ExperimentalAtomicApi

/**
 * The storage keys a store's session renders from variables, numbered by
 * the store: one per id looked up and per cursor paged past, kept apart
 * from the build's dense slots so that nothing a session renders is kept in
 * a table of the process. A store's number `n` is the slot index `n.inv()`,
 * negative. See `spec/runtime.md`, section 1.
 *
 * A text has one slot in a store. A rendering whose text the build names as
 * a constant takes the constant's slot; a constant the build names after
 * the store rendered its text is adopted, the two slots becoming twins the
 * store writes together. The build's constants on a type are read into the
 * table as the registry interns them, so finding one names nothing new.
 *
 * A variant for a type the plan did not list is resolved where the response
 * is read, off the store's thread, so the state is an immutable snapshot
 * replaced by compare-and-set, as the registry's is. A collection frees the
 * numbers nothing can name any more.
 */
@OptIn(ExperimentalAtomicApi::class)
internal class Keys {
    private class Table(
        /** The store's number of each text it rendered on the type. */
        val numbers: Map<String, Int>,
        /** The text of each number; null for a number freed, which the next text takes, lowest first. */
        val texts: List<String?>,
        /** The build's constants on the type, by text, as far as [scanned] reaches. */
        val constants: Map<String, Int>,
        /** How many of the registry's slots on the type are read into [constants]. */
        val scanned: Int,
    )

    private class State(val tables: Map<Int, Table>, val adoptions: List<Pair<Slot, Slot>>)

    private val state = AtomicReference(State(emptyMap(), emptyList()))

    /** The slot of a rendered key on [type]: the build's when it names the text, otherwise the store's number for it. */
    fun slot(type: TypeID, text: String): Slot {
        while (true) {
            val current = state.load()
            val (table, adoptions) = scanned(type, current.tables[type.raw] ?: EMPTY)
            val dense = table.constants[text]
            val known = table.numbers[text]
            val free = if (dense != null || known != null) -1 else table.texts.indexOf(null)
            val number = known ?: if (free >= 0) free else table.texts.size
            val next = when {
                dense != null || known != null -> table
                free >= 0 -> Table(table.numbers + (text to number), table.texts.toMutableList().also { it[number] = text }, table.constants, table.scanned)
                else -> Table(table.numbers + (text to number), table.texts + text, table.constants, table.scanned)
            }
            val slot = Slot(type, dense ?: number.inv())
            if (next === current.tables[type.raw] && adoptions.isEmpty()) return slot
            val updated = State(current.tables + (type.raw to next), current.adoptions + adoptions)
            if (state.compareAndSet(current, updated)) return slot
        }
    }

    /** The text of a slot: the build's for a dense one, the store's for one it numbered. */
    fun text(slot: Slot): String {
        if (slot.index >= 0) return Registry.storageKey(slot)
        return state.load().tables[slot.type.raw]?.texts?.getOrNull(slot.index.inv()) ?: ""
    }

    /**
     * Frees every number not in [kept]: the store passes what a live
     * resolution or scope took and every twin. Their texts go, the numbers
     * are used again lowest first, and each table shrinks to its highest
     * number in use. Returns the freed slots, for the store to drop the
     * records' entries under them.
     */
    fun free(kept: Set<Slot>): List<Slot> {
        while (true) {
            val current = state.load()
            val freed = ArrayList<Slot>()
            val tables = HashMap<Int, Table>(current.tables.size)
            for ((raw, table) in current.tables) {
                val type = TypeID(raw)
                val texts = table.texts.toMutableList()
                val numbers = HashMap(table.numbers)
                for (number in texts.indices) {
                    val text = texts[number] ?: continue
                    val slot = Slot(type, number.inv())
                    if (slot in kept) continue
                    texts[number] = null
                    numbers.remove(text)
                    freed.add(slot)
                }
                while (texts.isNotEmpty() && texts.last() == null) texts.removeAt(texts.lastIndex)
                tables[raw] = Table(numbers, texts, table.constants, table.scanned)
            }
            if (freed.isEmpty()) return freed
            if (state.compareAndSet(current, State(tables, current.adoptions))) return freed
        }
    }

    /** Forgets every key: the session ended, and the process keeps no text it rendered. */
    fun clear() {
        while (true) {
            val current = state.load()
            if (state.compareAndSet(current, State(emptyMap(), emptyList()))) return
        }
    }

    /**
     * Reads the constants the build named since the last time on every type
     * the store numbered a key on, making twins of a text the store rendered
     * first. Called at every resolution; free when the build named nothing.
     */
    fun reconcile() {
        while (true) {
            val current = state.load()
            var tables = current.tables
            var adoptions = current.adoptions
            for ((raw, table) in current.tables) {
                if (table.numbers.isEmpty() || table.scanned == Registry.slotCount(TypeID(raw))) continue
                val (next, fresh) = scanned(TypeID(raw), table)
                tables = tables + (raw to next)
                adoptions = adoptions + fresh
            }
            if (tables === current.tables) return
            if (state.compareAndSet(current, State(tables, adoptions))) return
        }
    }

    /** The twins made since the store last took them: the store's slot and the constant's. */
    fun takeAdoptions(): List<Pair<Slot, Slot>> {
        while (true) {
            val current = state.load()
            if (current.adoptions.isEmpty()) return emptyList()
            if (state.compareAndSet(current, State(current.tables, emptyList()))) return current.adoptions
        }
    }

    /** How many keys the store numbers on the type; for tests. */
    fun count(type: TypeID): Int = state.load().tables[type.raw]?.numbers?.size ?: 0

    /** The table with the registry's slots on the type read in, and the twins the newly read constants make. */
    private fun scanned(type: TypeID, table: Table): Pair<Table, List<Pair<Slot, Slot>>> {
        val total = Registry.slotCount(type)
        if (table.scanned == total) return table to emptyList()
        val constants = HashMap(table.constants)
        val adoptions = ArrayList<Pair<Slot, Slot>>()
        for (index in table.scanned until total) {
            val text = Registry.storageKey(Slot(type, index))
            if (constants.containsKey(text)) continue
            constants[text] = index
            val number = table.numbers[text] ?: continue
            adoptions.add(Slot(type, number.inv()) to Slot(type, index))
        }
        return Table(table.numbers, table.texts, constants, total) to adoptions
    }

    private companion object {
        val EMPTY = Table(emptyMap(), emptyList(), emptyMap(), 0)
    }
}
