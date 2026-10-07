package baton

import androidx.compose.runtime.Stable

/**
 * A view of one record through one selection: generated code's accessors
 * read the store through the anchor at each access, so a read in composition
 * registers the slot and a write invalidates its readers alone. Equal by
 * anchor. See `spec/runtime.md`, section 6.
 */
@Stable
interface Lens {
    @Generated
    val anchor: Anchor
}

/**
 * Where a lens stands: the record it reads and the owner whose variables and
 * store it reads under. Its readers, one per field shape, are the runtime's
 * contract with generated code and are defined with the store.
 */
@Stable
class Anchor @Generated constructor(val record: Record, val owner: Owner) {
    override fun equals(other: Any?): Boolean = other is Anchor && other.record === record && other.owner === owner
    override fun hashCode(): Int = record.hashCode() * 31 + owner.hashCode()
}

/** The scope a lens reads under: the operation's variables, the store, and the environment that can fetch. Defined with the store. */
class Owner internal constructor(val variables: Variables)
