package baton

/**
 * A script under `spec/scripts/`, decoded as `swift/Spec/Manifest.swift`
 * decodes it: steps run in order in one environment over one store, and
 * after any step the facts the runtime must then show. `spec/README.md`
 * documents the format.
 */
internal class Script(
    /** The script's name, the name of its file without the extension. */
    val name: String,
    /** Whether the store keeps an image, so that `relaunch` opens a second store over it. */
    val image: Boolean,
    /** How many released roots the store keeps alive; ten by default. */
    val buffer: Int,
    /** The store's default expiration in seconds, for an operation that states none. */
    val expiration: Double?,
    val steps: List<Step>,
    /** For a script of `relay/manifest.json`, the status the harvest gives it when Baton is not held to Relay's result. */
    val status: String? = null,
    /** Why the script has its status. */
    val note: String? = null,
    /** For a script of `relay/manifest.json`, the Relay test it came from. */
    val origin: String? = null,
) {
    /** An operation a step names: its name in its document and the variables it runs with, as JSON. */
    class Operation(val name: String, val variables: Map<String, Any?>)

    /** How the transport answers a request: with a response under `spec/`, or with a failure of a kind. */
    sealed interface Reply {
        class Response(val path: String) : Reply
        class Failure(val kind: FailureKind) : Reply
    }

    /** The failures a step may script: the transport throws, the server answers errors and no data, or a response the plan cannot read. */
    enum class FailureKind { TRANSPORT, REQUEST, MALFORMED }

    /** What a subscription's stream receives: an event, a failure, or the server's completion. */
    sealed interface Delivery {
        class Response(val path: String) : Delivery
        class Failure(val kind: FailureKind) : Delivery
        data object Complete : Delivery
    }

    /** What a step does, with its arguments. */
    sealed interface Action {
        val kind: String

        class Commit(val operation: Operation, val responses: List<String>) : Action { override val kind = "commit" }
        class Payload(val operation: Operation, val response: String) : Action { override val kind = "payload" }
        class Optimistic(val operation: Operation, val response: String, val name: String) : Action { override val kind = "optimistic" }
        class Resolve(val layer: String, val response: String) : Action { override val kind = "resolve" }
        class Revert(val layer: String) : Action { override val kind = "revert" }
        class Attach(val operation: Operation, val policy: FetchPolicy, val name: String, val reply: Reply?) : Action { override val kind = "attach" }
        class Answer(val handle: String, val reply: Reply) : Action { override val kind = "answer" }
        class Refetch(val handle: String, val reply: Reply) : Action { override val kind = "refetch" }
        class Retry(val handle: String, val reply: Reply?) : Action { override val kind = "retry" }
        class Release(val handle: String) : Action { override val kind = "release" }
        data object Collect : Action { override val kind = "collect" }
        class Advance(val seconds: Double) : Action { override val kind = "advance" }
        data object Invalidate : Action { override val kind = "invalidate" }
        data object Revalidate : Action { override val kind = "revalidate" }
        class Check(val operation: Operation) : Action { override val kind = "check" }
        data object Relaunch : Action { override val kind = "relaunch" }
        class Event(val handle: String, val delivery: Delivery) : Action { override val kind = "event" }
        class Active(val value: Boolean) : Action { override val kind = "active" }
        data object End : Action { override val kind = "end" }
    }

    /** A state as a script spells it: a word (`ready`), or a word and its kind (`{"failed": "transport"}`, `{"ended": null}`). */
    data class State(val word: String, val kind: String? = null, val tagged: Boolean = false) {
        override fun toString(): String = if (tagged) "$word(${kind ?: "null"})" else word
    }

    /**
     * A read a step expects: a case's row, through a handle's data or
     * through a lens made by hand over the root of an operation's kind. A
     * row may say instead what the read throws, a failure's kind in
     * [throws], or what a `@catch` read's result is, a JSON object in
     * [result]; such a row needs no [value].
     */
    class Read(
        val handle: String?,
        val operation: String?,
        val variables: Map<String, Any?>,
        val path: String,
        val value: Any?,
        val note: String?,
        val throws: String? = null,
        val result: Any? = null,
    )

    /** A field a batch notified: the record's key and the field's storage key. */
    data class Notification(val record: String, val field: String) {
        override fun toString(): String = "$record.$field"
    }

    class PhaseExpectation(val handle: String, val phase: State, val isRefreshing: Boolean?, val isStale: Boolean?)
    class FetchExpectation(val handle: String, val fetch: State)
    class StreamExpectation(val handle: String, val stream: State, val events: Long?, val resumptions: Long?)
    class SentRequest(val operation: String, val body: String)

    /** A log event: its name, and the value-free fields it carries that the script compares; a bare name compares the name alone. */
    class Event(val name: String, val fields: Map<String, Any?>) {
        override fun toString(): String =
            if (fields.isEmpty()) name else name + fields.entries.sortedBy { it.key }.joinToString(", ", "(", ")") { "${it.key}: ${it.value}" }
    }

    /** One step and the expectations beside it, each compared after the step. */
    class Step(
        val action: Action,
        val records: String?,
        val reads: List<Read>,
        val notified: List<Notification>?,
        val phases: List<PhaseExpectation>,
        val fetches: List<FetchExpectation>,
        val streams: List<StreamExpectation>,
        val answer: String?,
        val recordsHeld: List<String>?,
        val events: List<Event>?,
        val sent: List<SentRequest>?,
        val error: String?,
    )

    companion object {
        private val kinds = setOf(
            "commit", "payload", "optimistic", "resolve", "revert", "attach", "answer", "refetch", "retry", "release",
            "collect", "advance", "invalidate", "revalidate", "check", "relaunch", "event", "active", "end",
        )
        private val answers = setOf("memory", "image", "miss")

        /** The scripts the manifest lists, in the order they run. */
        val paths: List<String> by lazy { paths("manifest.json") }

        /** The scripts the manifest at [manifest] under `spec/` lists, in the order they run. */
        fun paths(manifest: String): List<String> {
            @Suppress("UNCHECKED_CAST")
            val json = Json.parse(Spec.text(manifest)) as Map<String, Any?>
            return (json["scripts"] as List<*>).map { it as String }
        }

        /** Reads a script by its path under `spec/`. */
        fun load(path: String): Script {
            val json = Json.parse(Spec.text(path)) as Map<*, *>
            return Script(
                name = json["name"] as String,
                image = json["image"] as Boolean? ?: false,
                buffer = (json["buffer"] as Long?)?.toInt() ?: 10,
                expiration = (json["expiration"] as Number?)?.toDouble(),
                steps = (json["steps"] as List<*>).map { step(it as Map<*, *>) },
                status = json["status"] as String?,
                note = json["note"] as String?,
                origin = json["origin"] as String?,
            )
        }

        private fun step(json: Map<*, *>): Step {
            // `answer` names a step when its value is an object of arguments, and the check's expected answer when it is a word.
            val answerIsExpectation = json["answer"] is String && json["answer"] in answers
            val named = json.keys.map { it as String }.filter { it in kinds && !(it == "answer" && answerIsExpectation) }
            require(named.size == 1) { "a step names one kind of step, not $named" }
            val kind = named.first()
            return Step(
                action = action(kind, json[kind] as Map<*, *>),
                records = json["records"] as String?,
                reads = (json["reads"] as List<*>?).orEmpty().map { read(it as Map<*, *>) },
                notified = (json["notified"] as List<*>?)?.map { entry ->
                    entry as Map<*, *>
                    Notification(entry["record"] as String, entry["field"] as String)
                },
                phases = oneOrMany(json["phase"]).map { PhaseExpectation(it["handle"] as String, state(it["phase"]), it["isRefreshing"] as Boolean?, it["isStale"] as Boolean?) },
                fetches = oneOrMany(json["fetch"]).map { FetchExpectation(it["handle"] as String, state(it["fetch"])) },
                streams = oneOrMany(json["stream"]).map { StreamExpectation(it["handle"] as String, state(it["stream"]), it["events"] as Long?, it["resumptions"] as Long?) },
                answer = if (answerIsExpectation) json["answer"] as String else null,
                recordsHeld = (json["records_held"] as List<*>?)?.map { it as String },
                events = (json["events"] as List<*>?)?.map { event(it) },
                sent = (json["sent"] as List<*>?)?.map { entry ->
                    entry as Map<*, *>
                    SentRequest(entry["operation"] as String, entry["body"] as String)
                },
                error = json["error"] as String?,
            )
        }

        /** An expectation given as one object or as a list of them. */
        private fun oneOrMany(value: Any?): List<Map<*, *>> = when (value) {
            null -> emptyList()
            is List<*> -> value.map { it as Map<*, *> }
            is Map<*, *> -> listOf(value)
            else -> error("an expectation is an object or a list of them, not $value")
        }

        private fun state(value: Any?): State = when (value) {
            is String -> State(value)
            is Map<*, *> -> {
                require(value.size == 1) { "a state is a word or an object of one key" }
                val (key, kind) = value.entries.first()
                State(key as String, kind as String?, tagged = true)
            }
            else -> error("a state is a word or an object of one key, not $value")
        }

        private fun event(value: Any?): Event = when (value) {
            is String -> Event(value, emptyMap())
            is Map<*, *> -> {
                require(value.size == 1) { "an event is a name or an object of one key" }
                val (key, fields) = value.entries.first()
                @Suppress("UNCHECKED_CAST")
                Event(key as String, fields as Map<String, Any?>)
            }
            else -> error("an event is a name or an object of one key, not $value")
        }

        private fun read(json: Map<*, *>): Read {
            @Suppress("UNCHECKED_CAST")
            val variables = (json["variables"] as Map<String, Any?>?).orEmpty()
            return Read(
                handle = json["handle"] as String?,
                operation = json["operation"] as String?,
                variables = variables,
                path = json["path"] as String,
                value = json["value"],
                note = json["note"] as String?,
                throws = json["throws"] as String?,
                result = json["result"],
            )
        }

        private fun action(kind: String, arguments: Map<*, *>): Action {
            fun string(key: String): String = arguments[key] as String? ?: error("a $kind step gives $key")
            fun operation(): Operation {
                @Suppress("UNCHECKED_CAST")
                val variables = (arguments["variables"] as Map<String, Any?>?).orEmpty()
                return Operation(string("operation"), variables)
            }
            fun failure(): FailureKind? = (arguments["failure"] as String?)?.let { FailureKind.valueOf(it.uppercase()) }
            fun reply(): Reply? {
                (arguments["response"] as String?)?.let { return Reply.Response(it) }
                return failure()?.let { Reply.Failure(it) }
            }
            fun requiredReply(): Reply = reply() ?: error("a $kind step gives a response or a failure")
            return when (kind) {
                "commit" -> Action.Commit(operation(), (arguments["responses"] as List<*>?)?.map { it as String } ?: listOf(string("response")))
                "payload" -> Action.Payload(operation(), string("response"))
                "optimistic" -> Action.Optimistic(operation(), string("response"), string("as"))
                "resolve" -> Action.Resolve(string("layer"), string("response"))
                "revert" -> Action.Revert(string("layer"))
                "attach" -> Action.Attach(operation(), policy(arguments["policy"] as String?), string("as"), reply())
                "answer" -> Action.Answer(string("handle"), requiredReply())
                "refetch" -> Action.Refetch(string("handle"), requiredReply())
                "retry" -> Action.Retry(string("handle"), reply())
                "release" -> Action.Release(string("handle"))
                "collect" -> Action.Collect
                "advance" -> Action.Advance((arguments["seconds"] as Number).toDouble())
                "invalidate" -> Action.Invalidate
                "revalidate" -> Action.Revalidate
                "check" -> Action.Check(operation())
                "relaunch" -> Action.Relaunch
                "event" -> {
                    val handle = string("handle")
                    if (arguments["complete"] == true) return Action.Event(handle, Delivery.Complete)
                    when (val reply = requiredReply()) {
                        is Reply.Response -> Action.Event(handle, Delivery.Response(reply.path))
                        is Reply.Failure -> Action.Event(handle, Delivery.Failure(reply.kind))
                    }
                }
                "active" -> Action.Active(arguments["value"] as Boolean)
                "end" -> Action.End
                else -> error("no step is named $kind")
            }
        }

        private fun policy(name: String?): FetchPolicy = when (name) {
            null, "storeOrNetwork" -> FetchPolicy.STORE_OR_NETWORK
            "storeAndNetwork" -> FetchPolicy.STORE_AND_NETWORK
            "networkOnly" -> FetchPolicy.NETWORK_ONLY
            "storeOnly" -> FetchPolicy.STORE_ONLY
            else -> error("no fetch policy is named $name")
        }
    }
}
