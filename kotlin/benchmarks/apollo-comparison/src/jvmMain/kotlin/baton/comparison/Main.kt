package baton.comparison

import java.io.File
import kotlinx.coroutines.runBlocking

/**
 * The side-by-side bench on the JVM: the paths of Baton's Fixture response
 * and of Apollo's, as `runComparison` passes them.
 */
fun main(arguments: Array<String>) {
    require(arguments.size == 2) { "usage: <characters-page-1.json> <fixture-apollo.json>" }
    val machine = "the JVM ${System.getProperty("java.vm.name")} ${System.getProperty("java.version")}, " +
        "${System.getProperty("os.name")} ${System.getProperty("os.version")} ${System.getProperty("os.arch")}"
    runBlocking {
        Comparison.run(File(arguments[0]).readBytes(), File(arguments[1]).readBytes(), machine) { println(it) }
    }
}
