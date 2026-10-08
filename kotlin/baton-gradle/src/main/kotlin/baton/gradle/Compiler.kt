package baton.gradle

import groovy.json.JsonSlurper
import java.io.File
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.nio.channels.FileChannel
import java.nio.file.StandardOpenOption
import java.security.MessageDigest
import java.util.Properties
import java.util.zip.ZipInputStream
import org.gradle.api.GradleException
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.provider.Property
import org.gradle.api.services.BuildService
import org.gradle.api.services.BuildServiceParameters

/** The release the plugin is versioned with and the checksum of its compiler bundle, from the resource the build stamps. */
class Release(val version: String, val bundleSha256: String) {
    companion object {
        fun load(): Release {
            val properties = Properties()
            val resource = Release::class.java.getResourceAsStream("/baton/gradle/release.properties")
                ?: throw IllegalStateException("the plugin's release.properties is missing")
            resource.use(properties::load)
            return Release(properties.getProperty("version"), properties.getProperty("bundleSha256"))
        }
    }
}

/** The compiler as `BATON_COMPILER` names it and as a bundle lists it. */
object Compiler {
    /** The binary `BATON_COMPILER` names: a `batonc`, or the host's variant of a bundle directory holding an `info.json`. */
    fun named(value: String, base: File): File {
        val path = File(value).let { if (it.isAbsolute) it else base.resolve(it) }
        if (path.isFile) return path
        val info = path.resolve("info.json")
        if (info.isFile) {
            val binary = path.resolve(Bundle.variant(info.readText(), Host.triple()))
            if (!binary.isFile) throw GradleException("the bundle at $path lists ${binary.relativeTo(path)}, which is not there")
            return binary
        }
        throw GradleException("BATON_COMPILER names $value, which is neither a batonc binary nor a bundle directory holding an info.json")
    }
}

/** The triple a host reports, as the bundle's `info.json` spells it. */
object Host {
    fun triple(os: String = System.getProperty("os.name"), arch: String = System.getProperty("os.arch")): String {
        val arm = arch.lowercase() in setOf("aarch64", "arm64")
        val name = os.lowercase()
        return when {
            name.startsWith("mac") -> if (arm) "arm64-apple-macosx" else "x86_64-apple-macosx"
            name.startsWith("linux") -> if (arm) "aarch64-unknown-linux-gnu" else "x86_64-unknown-linux-gnu"
            else -> throw GradleException("the release's bundle has no compiler for $os; set BATON_COMPILER to a batonc built for it")
        }
    }
}

/** The bundle's `info.json`, read as SwiftPM and the Bazel extension read it. */
object Bundle {
    /** The path, inside the bundle, of the variant listed for the triple. */
    fun variant(info: String, triple: String): String {
        val json = JsonSlurper().parseText(info) as? Map<*, *> ?: throw GradleException("info.json is not an object")
        val artifacts = json["artifacts"] as? Map<*, *> ?: throw GradleException("info.json lists no artifacts")
        val batonc = artifacts["batonc"] as? Map<*, *> ?: throw GradleException("info.json lists no batonc")
        val variants = batonc["variants"] as? List<*> ?: throw GradleException("info.json lists no variants of batonc")
        val listed = mutableListOf<String>()
        for (variant in variants) {
            val entry = variant as? Map<*, *> ?: continue
            val triples = (entry["supportedTriples"] as? List<*>).orEmpty().filterIsInstance<String>()
            if (triple in triples) return entry["path"] as? String ?: throw GradleException("the variant for $triple names no path")
            listed += triples
        }
        throw GradleException("the bundle lists no compiler for $triple, only $listed; set BATON_COMPILER to a batonc built for it")
    }
}

/** `baton.json` as the plugin reads it: the files it names beside itself, to declare as inputs. */
object Configuration {
    /** The schema and the schema extensions, each relative to the configuration's directory; an extension may be a directory. */
    fun files(text: String, directory: File): List<File> {
        val json = JsonSlurper().parseText(text) as? Map<*, *> ?: throw GradleException("baton.json is not an object")
        val files = mutableListOf<File>()
        (json["schema"] as? String)?.let { files += directory.resolve(it) }
        for (entry in (json["schemaExtensions"] as? List<*>).orEmpty()) {
            (entry as? String)?.let { files += directory.resolve(it) }
        }
        return files
    }
}

/**
 * The release's compiler, fetched once into the Gradle user home and shared
 * by every project of the build: the bundle SwiftPM and Bazel download,
 * checked against the checksum the release stamped, with the host's variant
 * taken from its `info.json`.
 */
abstract class CompilerService : BuildService<CompilerService.Parameters> {
    interface Parameters : BuildServiceParameters {
        val version: Property<String>
        val bundleSha256: Property<String>
        val cacheDirectory: DirectoryProperty
        val offline: Property<Boolean>
    }

    /** The `batonc` for this host. */
    @Synchronized
    fun compiler(): File {
        val version = parameters.version.get()
        val directory = parameters.cacheDirectory.get().asFile.resolve(version)
        val bundle = directory.resolve("batonc.artifactbundle")
        if (!bundle.resolve("info.json").isFile) {
            if (parameters.offline.get()) {
                throw GradleException("the compiler bundle of $version is not under $directory and the build is offline; set BATON_COMPILER to a built batonc")
            }
            directory.mkdirs()
            // Another build on the machine may be fetching the same bundle.
            FileChannel.open(directory.resolve("lock").toPath(), StandardOpenOption.CREATE, StandardOpenOption.WRITE).use { channel ->
                channel.lock().use {
                    if (!bundle.resolve("info.json").isFile) fetch(version, directory, bundle)
                }
            }
        }
        val binary = bundle.resolve(Bundle.variant(bundle.resolve("info.json").readText(), Host.triple()))
        if (!binary.isFile) throw GradleException("the bundle of $version lists ${binary.relativeTo(bundle)}, which is not there; delete $directory to fetch it again")
        binary.setExecutable(true)
        return binary
    }

    private fun fetch(version: String, directory: File, bundle: File) {
        val url = "https://github.com/shergin/baton/releases/download/v$version/batonc.artifactbundle.zip"
        val zip = directory.resolve("batonc.artifactbundle.zip")
        val client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build()
        val response = client.send(HttpRequest.newBuilder(URI.create(url)).build(), HttpResponse.BodyHandlers.ofFile(zip.toPath()))
        if (response.statusCode() != 200) throw GradleException("fetching $url answered ${response.statusCode()}")
        val checksum = sha256(zip)
        val expected = parameters.bundleSha256.get()
        if (checksum != expected) {
            zip.delete()
            throw GradleException("$url has the checksum $checksum, not the $expected the release stamped")
        }
        // Unpacked beside its final name and moved there whole, so a bundle
        // that is there is complete.
        val staging = directory.resolve("unpacking")
        staging.deleteRecursively()
        unzip(zip, staging)
        val unpacked = staging.resolve(bundle.name)
        if (!unpacked.resolve("info.json").isFile) throw GradleException("$url holds no ${bundle.name}/info.json")
        bundle.deleteRecursively()
        if (!unpacked.renameTo(bundle)) throw GradleException("could not move the bundle into $bundle")
        staging.deleteRecursively()
        zip.delete()
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val read = stream.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun unzip(zip: File, into: File) {
        val root = into.canonicalFile
        ZipInputStream(zip.inputStream().buffered()).use { stream ->
            while (true) {
                val entry = stream.nextEntry ?: break
                val target = File(root, entry.name).canonicalFile
                if (!target.path.startsWith(root.path + File.separator)) throw GradleException("the bundle holds an entry outside itself, ${entry.name}")
                if (entry.isDirectory) {
                    target.mkdirs()
                } else {
                    target.parentFile.mkdirs()
                    target.outputStream().use { stream.copyTo(it) }
                }
                stream.closeEntry()
            }
        }
    }
}
