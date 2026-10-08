package baton

import java.io.File
import java.util.UUID

/** An image's path in the temporary directory, deleted with its log and marker when the test is done. */
internal class TemporaryImage {
    val path: String = File(System.getProperty("java.io.tmpdir"), "baton-${UUID.randomUUID()}.sqlite").path

    fun delete() {
        for (suffix in listOf("", "-wal", "-shm", "-discard")) File(path + suffix).delete()
    }
}
