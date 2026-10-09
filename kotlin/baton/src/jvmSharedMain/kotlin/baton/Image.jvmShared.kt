package baton

import java.io.File
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers

// The image's platform piece the JVM and Android share: the file operations
// over `java.io` and the writer's thread. The driver, and where an image
// named but not placed lives, are each target's own.

internal actual fun imageFileExists(path: String): Boolean = File(path).exists()

internal actual fun deleteImageFile(path: String) {
    File(path).delete()
}

internal actual fun touchImageFile(path: String) {
    File(path).createNewFile()
}

internal actual fun makeImageDirectory(path: String) {
    File(path).absoluteFile.parentFile?.mkdirs()
}

internal actual fun canonicalImagePath(path: String): String {
    val file = File(path).absoluteFile
    // The nearest directory that exists is resolved, and the rest appended,
    // so that nothing is created here.
    var directory: File? = file.parentFile
    val rest = ArrayList<String>()
    rest.add(file.name)
    while (directory != null && !directory.exists()) {
        rest.add(directory.name)
        directory = directory.parentFile
    }
    val base = directory?.canonicalFile ?: return file.path
    return rest.asReversed().fold(base) { parent, name -> File(parent, name) }.path
}

internal actual fun imageWriterDispatcher(): CoroutineDispatcher = Dispatchers.IO.limitedParallelism(1)
