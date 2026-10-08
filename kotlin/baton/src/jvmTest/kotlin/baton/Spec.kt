package baton

import java.io.File

/** The files under `spec/`: the manifest's cases, their responses and their dumps. */
internal object Spec {
    val directory: File = generateSequence(File(System.getProperty("user.dir")).absoluteFile) { it.parentFile }
        .map { File(it, "spec") }
        .first { File(it, "manifest.json").isFile }

    fun bytes(path: String): ByteArray = File(directory, path).readBytes()

    fun text(path: String): String = File(directory, path).readText()

    /**
     * A row of a case's `reads`: the response keys and list indices from the
     * root, the value a lens yields there as JSON read by `Json`, and the
     * rule that reads it otherwise than the response, when one does.
     */
    class Read(val path: String, val value: Any?, val note: String?) {
        override fun toString(): String = path
    }

    /** A case of the manifest: the responses an operation's server sent, the dump the store holds after them, and what a lens reads. */
    class Case(
        val name: String,
        val operation: String,
        val kind: OperationKind,
        val variables: Variables,
        val responses: List<String>,
        val records: String,
        val reads: List<Read>,
    ) {
        /** The generated operation the case runs, from `spec/sources`. */
        val type: OperationType<*>? get() = operation(operation)

        val plan: Plan? get() = type?.plan

        /**
         * Commits the responses into [store] under the case's root: one
         * response as a payload, the parts of an incremental one as an app
         * receives them, the first complete and each later one's objects at
         * the records their paths name.
         */
        fun commit(store: Store) {
            val plan = checkNotNull(plan) { "$name: no plan for $operation" }
            val resolved = store.resolve(plan, variables)
            val rootKey = Store.rootKey(kind)
            if (responses.size == 1) {
                store.commit(Ingest.normalize(bytes(responses[0]), resolved, rootKey))
                return
            }
            val first = Ingest.normalizeFirstPart(bytes(responses[0]), resolved, rootKey, complete = true)
            store.commit(first.changes)
            val delivery = Delivery(store, resolved)
            delivery.announce(first.pending)
            for (response in responses.drop(1)) {
                val part = Ingest.incremental(bytes(response))
                delivery.announce(part.pending)
                for (item in delivery.objects(part)) store.commit(item.normalize())
                for (failure in delivery.failures(part)) store.commit(failure.changes)
            }
        }

        /** The first line where the store's dump differs from the case's, or null when they agree. */
        fun difference(store: Store): String? = Spec.difference(store.dump(), text(records), records)

        override fun toString(): String = name
    }

    val cases: List<Case> by lazy {
        @Suppress("UNCHECKED_CAST")
        val manifest = Json.parse(text("manifest.json")) as Map<String, Any?>
        check(manifest["format"] == 3L) { "the harness reads format 3 of the manifest" }
        @Suppress("UNCHECKED_CAST")
        (manifest["cases"] as List<Map<String, Any?>>).map { entry ->
            @Suppress("UNCHECKED_CAST")
            val variables = (entry["variables"] as Map<String, Any?>?).orEmpty().mapValues { Json.variable(it.value) }
            Case(
                name = entry["name"] as String,
                operation = entry["operation"] as String,
                kind = OperationKind.valueOf((entry["kind"] as String).uppercase()),
                variables = Variables(variables),
                responses = (entry["responses"] as List<*>).map { it as String },
                records = entry["records"] as String,
                reads = (entry["reads"] as List<*>?).orEmpty().map { row ->
                    row as Map<*, *>
                    Read(row["path"] as String, row["value"], row["note"] as String?)
                },
            )
        }
    }

    fun case(name: String): Case = cases.first { it.name == name }

    /**
     * The operation [name] as the compiler generated it from `spec/sources`
     * into the package `baton.spec`: its class's companion, which holds the
     * plan and builds the root lens; null when no source declares it.
     */
    fun operation(name: String): OperationType<*>? {
        val type = try {
            Class.forName("baton.spec.$name")
        } catch (_: ClassNotFoundException) {
            return null
        }
        return type.getField("Companion").get(null) as OperationType<*>
    }

    /** The first line where [actual] differs from [expected], saying where, or null when they are the same text. */
    fun difference(actual: String, expected: String, name: String): String? {
        if (actual == expected) return null
        val actualLines = actual.split("\n")
        val expectedLines = expected.split("\n")
        val line = actualLines.indices.firstOrNull { it >= expectedLines.size || actualLines[it] != expectedLines[it] } ?: actualLines.size
        val store = actualLines.getOrElse(line) { "<end>" }
        val dump = expectedLines.getOrElse(line) { "<end>" }
        return "the store differs from $name at line ${line + 1}:\n  store: $store\n  dump:  $dump"
    }
}
