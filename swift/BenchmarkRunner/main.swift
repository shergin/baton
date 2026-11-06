// The bench suite's executable: every number in BENCHMARKS.md comes from
// `swift run -c release BatonBenchmarks`. The suite itself is the
// `BatonBench` library, so that a device can run its sections too.
import BatonBench

await BatonBench.main(arguments: CommandLine.arguments)
