import Foundation

/// Hydration: filling records from the image. It runs inside the availability
/// check, on the main actor, holding the image's connection; `Disk` writes
/// the rows this reads.
extension Store {
    /// Reads the record's row and fills the slots the record lacks, through
    /// the batch, which notifies the fills when it ends. Returns whether the
    /// image had the row.
    func hydrate(_ record: Record, from disk: Disk, _ batch: inout Batch) -> Bool {
        // A row the image is told to forget reads as missing until a
        // response writes the record again.
        if forgotten(record) { return false }
        record.setHydrated()
        // A record that held nothing has had no reader to notify. The slots
        // filled are noted after the row is read, so the batch is not
        // captured by the reading closure.
        let observed = !record.isEmpty
        var filled: [Slot] = []
        let found = disk.record(record.key) { bytes in
            var reader = RowReader(bytes)
            guard let flags = reader.byte(), reader.varint() != nil else { return }
            if flags & 1 != 0 {
                if !observed { record.setDeleted(true) }
                return
            }
            while !reader.isAtEnd {
                // A row that stops making sense is used as far as it went:
                // what follows reads as missing, and the operation refetches.
                guard let name = reader.index(), let slot = disk.slot(name, on: record.type),
                      let (value, error) = reader.value(disk, target: target)
                else { return }
                if record.fill(slot, value, error: error), observed { filled.append(slot) }
            }
        }
        for slot in filled { batch.touched(record, slot, value: .missing, error: nil) }
        if found { hydratedRecords += 1 }
        return found
    }

    /// Reads one field of the query root, which the image stores a row per
    /// field, through the batch. Returns whether the field was filled.
    func hydrateRoot(_ slot: Slot, from disk: Disk, _ batch: inout Batch) -> Bool {
        var filled = false
        _ = disk.rootField(slot.storageKey) { bytes in
            var reader = RowReader(bytes)
            guard let (value, error) = reader.value(disk, target: target) else { return }
            filled = root.fill(slot, value, error: error)
        }
        guard filled else { return false }
        hydratedRootSlots.insert(slot.index)
        batch.touched(root, slot, value: .missing, error: nil)
        return true
    }

}

