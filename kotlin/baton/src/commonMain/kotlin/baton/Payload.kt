package baton

/** Bytes in a response's shape, as the door takes them: a server's, or an optimistic response a builder rendered. */
class Payload(val bytes: ByteArray) {
    constructor(json: String) : this(json.encodeToByteArray())

    override fun equals(other: Any?): Boolean = other is Payload && other.bytes.contentEquals(bytes)
    override fun hashCode(): Int = bytes.contentHashCode()
}
