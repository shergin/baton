package baton

import kotlin.concurrent.atomics.AtomicInt
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
 * Locked, as the Swift runtime's table is, because a variant for a type the
 * plan did not list is resolved where the response is read, off the store's
 * thread. The tables change in place under the lock, so a session that
 * renders many texts on one type pays for each once. A collection frees the
 * numbers nothing can name any more.
 */
@OptIn(ExperimentalAtomicApi::class)
internal class Keys {
    /** The store's numbers on one type, read and written under the lock. */
    private class Table {
        /** The store's number of each text it rendered on the type. */
        val numbers = HashMap<String, Int>()
        /** The text of each number; null for a number freed. */
        val texts = ArrayList<String?>()
        /** The numbers freed and not taken again, the lowest last, so the next text takes the lowest. */
        val free = ArrayList<Int>()
        /** The build's constants on the type, by text, as far as [scanned] reaches. */
        val constants = HashMap<String, Int>()
        /** How many of the registry's slots on the type are read into [constants]. */
        var scanned = 0
    }

    private val lock = Lock()
    /** The tables by `TypeID.raw`, under [lock]. */
    private val tables = HashMap<Int, Table>()
    /** The twins made since the store last took them, under [lock]. */
    private val adoptions = ArrayList<Pair<Slot, Slot>>()
    /** How many times numbers were freed or forgotten, read without the lock. */
    private val generations = AtomicInt(0)

    /** The slot of a rendered key on [type]: the build's when it names the text, otherwise the store's number for it. */
    fun slot(type: TypeID, text: String): Slot = lock.withLock {
        val table = tables.getOrPut(type.raw) { Table() }
        scan(type, table)
        table.constants[text]?.let { return Slot(type, it) }
        table.numbers[text]?.let { return Slot(type, it.inv()) }
        val number = if (table.free.isEmpty()) {
            table.texts.add(text)
            table.texts.lastIndex
        } else {
            table.free.removeAt(table.free.lastIndex).also { table.texts[it] = text }
        }
        table.numbers[text] = number
        Slot(type, number.inv())
    }

    /**
     * How many times numbers were freed or forgotten. A scope that cached
     * slots under an earlier generation renders its keys again, since a
     * number it holds may have been freed and taken by another text: Kotlin
     * has no deinit to tell the keys a scope still holds one.
     */
    val generation: Int get() = generations.load()

    /** The text of a slot: the build's for a dense one, the store's for one it numbered. */
    fun text(slot: Slot): String {
        if (slot.index >= 0) return Registry.storageKey(slot)
        return lock.withLock { tables[slot.type.raw]?.texts?.getOrNull(slot.index.inv()) ?: "" }
    }

    /**
     * Frees every number not in [kept]: the store passes what a live
     * resolution or scope took and every twin. Their texts go, the numbers
     * are used again lowest first, and each table shrinks to its highest
     * number in use. Returns the freed slots, for the store to drop the
     * records' entries under them.
     */
    fun free(kept: Set<Slot>): List<Slot> = lock.withLock {
        val freed = ArrayList<Slot>()
        for ((raw, table) in tables) {
            val type = TypeID(raw)
            val texts = table.texts
            for (number in texts.indices) {
                val text = texts[number] ?: continue
                val slot = Slot(type, number.inv())
                if (slot in kept) continue
                texts[number] = null
                table.numbers.remove(text)
                freed.add(slot)
            }
            while (texts.isNotEmpty() && texts.last() == null) texts.removeAt(texts.lastIndex)
            table.free.clear()
            for (number in texts.indices.reversed()) if (texts[number] == null) table.free.add(number)
        }
        if (freed.isNotEmpty()) generations.addAndFetch(1)
        freed
    }

    /** Forgets every key: the session ended, and the process keeps no text it rendered. */
    fun clear() {
        lock.withLock {
            tables.clear()
            adoptions.clear()
            generations.addAndFetch(1)
        }
    }

    /**
     * Reads the constants the build named since the last time on every type
     * the store numbered a key on, making twins of a text the store rendered
     * first. Called at every resolution; free when the build named nothing.
     */
    fun reconcile() {
        lock.withLock {
            for ((raw, table) in tables) {
                if (table.numbers.isEmpty()) continue
                scan(TypeID(raw), table)
            }
        }
    }

    /** The twins made since the store last took them: the store's slot and the constant's. */
    fun takeAdoptions(): List<Pair<Slot, Slot>> = lock.withLock {
        if (adoptions.isEmpty()) return emptyList()
        val taken = ArrayList(adoptions)
        adoptions.clear()
        taken
    }

    /** How many keys the store numbers on the type; for tests. */
    fun count(type: TypeID): Int = lock.withLock { tables[type.raw]?.numbers?.size ?: 0 }

    /** Reads the registry's slots on the type past [Table.scanned] into the constants, making a twin of each text the store rendered first. */
    private fun scan(type: TypeID, table: Table) {
        val total = Registry.slotCount(type)
        if (table.scanned == total) return
        for (index in table.scanned until total) {
            val text = Registry.storageKey(Slot(type, index))
            if (table.constants.containsKey(text)) continue
            table.constants[text] = index
            val number = table.numbers[text] ?: continue
            adoptions.add(Slot(type, number.inv()) to Slot(type, index))
        }
        table.scanned = total
    }
}
