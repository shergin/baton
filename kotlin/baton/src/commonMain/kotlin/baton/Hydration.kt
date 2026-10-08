package baton

// Hydration: filling records from the image. It runs inside the
// availability check, on the store's thread, holding the image's
// connection; `Disk` writes the rows this reads. See `spec/runtime.md`,
// section 5.

/**
 * Reads the record's row and fills the slots the record lacks, once; a slot
 * that holds a value is left alone, since memory is the truth. Returns
 * whether the image had the row.
 */
internal fun Store.hydrate(record: Record, disk: Disk, batch: Store.Batch): Boolean {
    // A row the image is told to forget reads as missing until a response writes the record again.
    if (forgotten(record)) return false
    record.setHydrated()
    // A record that held nothing has had no reader to notify.
    val observed = !record.isEmpty
    val found = disk.record(record.key) { bytes ->
        val reader = RowReader(bytes)
        val flags = reader.byte() ?: return@record
        reader.varint() ?: return@record
        if (flags and 1 != 0) {
            if (!observed) record.setDeleted(true)
            return@record
        }
        while (!reader.isAtEnd) {
            // A row that stops making sense is used as far as it went: what
            // follows reads as missing, and the operation refetches.
            val name = reader.index() ?: return@record
            val slot = disk.slot(name, record.type, keys) ?: return@record
            val (value, error) = reader.value(disk::type, ::target) ?: return@record
            if (slot.index < 0) imageSlots.add(slot)
            if (!record.fill(slot, value, error)) continue
            if (observed) batch.touched(record, slot, null, twin = false)
            twins[slot]?.let { twin -> record.fill(twin, value, error) }
        }
    }
    if (found) hydratedRecords += 1
    return found
}

/** Reads one field of the query root, which the image stores a row per field. Returns whether the field was filled. */
internal fun Store.hydrateRoot(slot: Slot, disk: Disk, batch: Store.Batch): Boolean {
    var filled = false
    disk.rootField(keys.text(slot)) { bytes ->
        val (value, error) = RowReader(bytes).value(disk::type, ::target) ?: return@rootField
        filled = root.fill(slot, value, error)
        if (filled) twins[slot]?.let { twin -> root.fill(twin, value, error) }
    }
    if (!filled) return false
    hydratedRootSlots.add(slot.index)
    batch.touched(root, slot, null, twin = false)
    return true
}
