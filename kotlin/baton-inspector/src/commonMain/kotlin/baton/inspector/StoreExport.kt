package baton.inspector

import baton.Store
import baton.dump

/**
 * The store as `spec/` freezes it: every record by key, each a map from
 * storage key to value, a link written as Relay writes it (`{"__ref": key}`,
 * `{"__refs": [key]}`), the record's type as `__typename`, field errors under
 * `__errors`, and a deleted record as null. Keys are sorted and each record
 * is one line, so a change to identity or layout is a reviewable diff, and
 * a bug report's export can become a fixture.
 */
object StoreExport {
    /** Returns the store's records in the dump format; called on the store's thread. */
    fun text(store: Store): String = store.dump()
}
