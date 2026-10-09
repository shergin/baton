package baton

/** What the build knows and the store learns about which types satisfy which abstract type. */
internal object Membership {
    private var compiled: Array<BooleanArray> = emptyArray()
    private var learned: Array<BooleanArray> = emptyArray()

    fun register(condition: TypeID, types: List<TypeID>) {
        for (type in types) compiled = set(compiled, condition, type)
    }

    fun learn(type: TypeID, condition: TypeID) {
        learned = set(learned, condition, type)
    }

    fun learned(type: TypeID, condition: TypeID): Boolean = get(learned, condition, type)

    fun includes(type: TypeID, condition: TypeID): Boolean = get(compiled, condition, type) || learned(type, condition)

    private fun set(table: Array<BooleanArray>, condition: TypeID, type: TypeID): Array<BooleanArray> {
        var rows = table
        if (condition.raw >= rows.size) rows = Array(condition.raw + 1) { rows.getOrNull(it) ?: BooleanArray(0) }
        var row = rows[condition.raw]
        if (type.raw >= row.size) row = row.copyOf(type.raw + 1)
        row[type.raw] = true
        rows[condition.raw] = row
        return rows
    }

    private fun get(table: Array<BooleanArray>, condition: TypeID, type: TypeID): Boolean {
        val row = table.getOrNull(condition.raw) ?: return false
        return type.raw < row.size && row[type.raw]
    }
}
