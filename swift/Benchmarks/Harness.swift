// The harness: what a run is asked for, how a row is measured, and the
// report every row goes into.
//
//   swift run -c release BatonBenchmarks
//   swift run -c release BatonBenchmarks --quick            three samples a row, for CI
//   swift run -c release BatonBenchmarks --counts           the deterministic counts alone
//   swift run -c release BatonBenchmarks --only ingest,commit
//   swift run -c release BatonBenchmarks --json report.json
//   swift run -c release BatonBenchmarks --repeat 3
//   swift run -c release BatonBenchmarks --profile "same payload"   loop one row for xctrace
import Darwin
import Foundation
import Observation
import Synchronization

/// What the command line asked of the run.
public struct Options: Sendable {
    /// Three samples a row, so CI runs every bench once without waiting for
    /// numbers worth recording.
    public var quick = false
    /// Only the deterministic counts, one `count <name> <value>` a line,
    /// which CI compares with `benchmarks/counts.txt`; a change to what a
    /// commit notifies, logs or allocates shows as a diff, where a timing
    /// would show as noise.
    public var countsOnly = false
    /// The sections to run, by name; nil runs every section.
    public var only: Set<String>?
    /// Where to write the report as JSON, if anywhere.
    public var json: String?
    /// How many times to run the selected sections in this process.
    public var repeats = 1
    /// A row to loop for a profiler, named by a substring of its label; the
    /// run prints the executable's load address, waits for the profiler to
    /// attach, loops the row and exits.
    public var profile: String?
    /// How long the profiled row loops, in seconds.
    public var profileSeconds = 5.0
    /// A child-process entry (`--launch`, `--anilist-launch`) and the image
    /// path it takes.
    public var launch: (flag: String, path: String)?

    public init() {}

    /// Parses the arguments, the executable's name first. Throws on an
    /// argument it does not know.
    public init(arguments: [String]) throws {
        var rest = arguments.dropFirst()[...]
        if rest.count == 2, let flag = rest.first, flag.hasPrefix("--launch") || flag.hasPrefix("--anilist-launch") {
            launch = (flag, rest.last!)
            return
        }
        func value(for flag: String) throws -> String {
            guard let next = rest.popFirst() else { throw OptionError(message: "\(flag) takes a value") }
            return next
        }
        while let argument = rest.popFirst() {
            switch argument {
            case "--quick": quick = true
            case "--counts": countsOnly = true
            case "--only": only = Set(try value(for: argument).split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            case "--json": json = try value(for: argument)
            case "--repeat":
                guard let count = Int(try value(for: argument)), count > 0 else { throw OptionError(message: "--repeat takes a positive number") }
                repeats = count
            case "--profile": profile = try value(for: argument)
            case "--profile-seconds":
                guard let seconds = Double(try value(for: argument)), seconds > 0 else { throw OptionError(message: "--profile-seconds takes a positive number") }
                profileSeconds = seconds
            default: throw OptionError(message: "unknown argument \(argument)")
            }
        }
    }
}

public struct OptionError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The options of the run, set once by `main`.
@MainActor var options = Options()

/// The section being measured, for the report.
@MainActor var currentSection = ""

/// The counting of allocations: every malloc in the process reported to
/// the allocator's logging hook while a row's extra sample runs. The hook
/// is the one Instruments uses, reached by name since the headers do not
/// export it to Swift; it is installed for the counted sample alone, so
/// no timed sample pays the atomic add per allocation.
enum Allocations {
    typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void
    nonisolated(unsafe) private static let hook = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger")?.assumingMemoryBound(to: Optional<Logger>.self)
    private static let count = Atomic<Int>(0)

    /// The allocations `body` makes, on every thread; nil when the hook is
    /// not there to count them.
    @MainActor
    static func during(_ body: () -> Void) -> Int? {
        guard let hook else { body(); return nil }
        let before = count.load(ordering: .relaxed)
        hook.pointee = { type, _, _, _, _, _ in
            // Bit 2 marks an allocation; a reallocation carries it too.
            if type & 2 != 0 { Allocations.count.add(1, ordering: .relaxed) }
        }
        body()
        hook.pointee = nil
        return count.load(ordering: .relaxed) - before
    }
}

/// One measured row of the report.
public struct Row: Sendable {
    public let section: String
    public let label: String
    /// How many operations a sample's body performs; the figures are per
    /// operation.
    public let ops: Int
    /// The samples, in nanoseconds for the whole body, in the order taken.
    public let samples: [Double]
    /// The allocations one run of the body makes, counted apart from the
    /// timed samples; nil where they are not counted.
    public let allocations: Int?

    var best: Double { samples.min()! / Double(ops) }
    var median: Double { samples.sorted()[samples.count / 2] / Double(ops) }
}

/// The report of a run: its rows and counts, written as JSON when asked.
@MainActor
final class Report {
    private(set) var rows: [Row] = []
    private(set) var counts: [(name: String, value: Int)] = []

    func add(_ row: Row) { rows.append(row) }
    func add(count name: String, _ value: Int) { counts.append((name, value)) }

    /// The report as JSON: the machine, the run and every row and count.
    func json() throws -> Data {
        var load = [Double](repeating: 0, count: 3)
        _ = getloadavg(&load, 3)
        let document: [String: Any] = [
            "date": ISO8601DateFormatter().string(from: Date()),
            "machine": Report.machine,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "load": load,
            "quick": options.quick,
            "rows": rows.map { row -> [String: Any] in
                var object: [String: Any] = [
                    "section": row.section, "label": row.label, "ops": row.ops,
                    "unit": "ns", "samples": row.samples, "best": row.best, "median": row.median,
                ]
                if let allocations = row.allocations { object["allocations"] = allocations }
                return object
            },
            "counts": counts.map { ["name": $0.name, "value": $0.value] },
        ]
        return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    }

    /// The processor's name, as the kernel reports it.
    private static var machine: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        var buffer = [UInt8](repeating: 0, count: size + 1)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

@MainActor let suiteReport = Report()

/// Runs a section when the run selects it, under its name and with its
/// headline printed first.
@MainActor
func section(_ name: String, _ headline: String? = nil, _ body: () async throws -> Void) async rethrows {
    if let only = options.only, !only.contains(name) { return }
    currentSection = name
    if !options.countsOnly { print(headline.map { "\(name): \($0)" } ?? name) }
    try await body()
}

/// Records a count that does not depend on the machine: printed as `line`
/// in a normal run, when there is one, and as `count <name> <value>` under
/// `--counts`.
@MainActor
func count(_ name: String, _ value: Int, _ line: String) {
    suiteReport.add(count: name, value)
    if options.countsOnly {
        print("count \(name) \(value)")
    } else if !line.isEmpty {
        print(line)
    }
}

/// How many samples a measurement asked for `iterations` takes.
@MainActor
func rounds(_ iterations: Int) -> Int { options.quick ? 3 : iterations }

func format(_ nanoseconds: Double) -> String {
    nanoseconds >= 1_000_000 ? String(format: "%8.2f ms", nanoseconds / 1_000_000)
        : nanoseconds >= 1_000 ? String(format: "%8.2f µs", nanoseconds / 1_000)
        : String(format: "%8.1f ns", nanoseconds)
}

/// Records and prints a row from its samples.
@MainActor
func report(_ label: String, _ samples: [Double], ops: Int, allocations: Int? = nil) {
    let row = Row(section: currentSection, label: label, ops: ops, samples: samples, allocations: allocations)
    suiteReport.add(row)
    if options.countsOnly { return }
    let line = "  \(label.padding(toLength: 64, withPad: " ", startingAt: 0)) best \(format(row.best))   median \(format(row.median))"
    print(allocations.map { "\(line)   allocs \($0)" } ?? line)
}

/// Times `body` alone, `iterations` times; `setup` runs before each sample,
/// off the clock. An `observer` counts what its scopes received during the
/// bodies only. The last sample counts the body's allocations instead of
/// its time, since the counting hook would slow it: the row runs as many
/// times as it asked and no more, which a setup that counts samples
/// relies on. A row given a `gate` name prints that count under
/// `--counts`, as `allocations-<gate>`, for `benchmarks/counts.txt` to hold.
@MainActor
func measure(_ label: String, iterations: Int = 20, ops: Int = 1, observer: Observer? = nil, gate: String? = nil, setup: () -> Void = {}, _ body: () -> Void) {
    if let profile = options.profile {
        if label.localizedCaseInsensitiveContains(profile) { profileLoop(label, setup: setup, body) }
        return
    }
    let total = rounds(iterations)
    var samples: [Double] = []
    var allocations: Int?
    for index in 0..<total {
        setup()
        // A row asked for one sample alone is timed and not counted.
        if index == total - 1, total > 1 {
            allocations = Allocations.during(body)
        } else {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
        }
        observer?.settle()
    }
    report(label, samples, ops: ops, allocations: allocations)
    if let gate, let allocations { count("allocations-\(gate)", allocations, "") }
}

/// Times an asynchronous step by hand: `body` returns the nanoseconds it
/// wants counted, so setup and teardown stay off the clock. Allocations are
/// not counted: the body awaits, and other work shares its time.
@MainActor
func measureEach(_ label: String, iterations: Int = 20, ops: Int = 1, _ body: () async -> UInt64) async {
    if options.profile != nil { return }
    var samples: [Double] = []
    for _ in 0..<rounds(iterations) { samples.append(Double(await body())) }
    report(label, samples, ops: ops)
}

/// Loops one row for a profiler: prints the executable's load address, so
/// the samples can be symbolicated, waits for the profiler to attach, runs
/// the row for `profileSeconds` and exits. `scripts/profile-bench.sh` drives
/// it.
@MainActor
private func profileLoop(_ label: String, setup: () -> Void, _ body: () -> Void) -> Never {
    var info = Dl_info()
    dladdr(UnsafeRawPointer(#dsohandle), &info)
    print("profiling \(label)")
    print("load-address 0x\(String(UInt(bitPattern: info.dli_fbase), radix: 16))")
    fflush(stdout)
    Thread.sleep(forTimeInterval: 1.5)
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(options.profileSeconds * 1e9)
    var samples: [Double] = []
    repeat {
        setup()
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start))
    } while DispatchTime.now().uptimeNanoseconds < deadline
    let sorted = samples.sorted()
    print("profiled \(samples.count) runs: best \(format(sorted[0])), median \(format(sorted[sorted.count / 2]))")
    exit(0)
}

/// Counts the notifications the observation scopes it starts receive. A
/// scope fires once, and one that a sample did not fire stays armed into the
/// next sample's setup, so each `observe` opens a round of its own and only
/// what a round received before `settle` counts.
@MainActor
final class Observer {
    private final class Round: @unchecked Sendable {
        var fired = 0
    }

    /// What the settled rounds received.
    private(set) var fired = 0
    private var round = Round()

    /// Registers one scope per element, each reading through `read`.
    func observe<Element>(_ elements: [Element], _ read: (Element) -> Void) {
        let round = Round()
        self.round = round
        for element in elements {
            withObservationTracking { read(element) } onChange: { round.fired += 1 }
        }
    }

    /// What the open round has received so far.
    var pending: Int { round.fired }

    /// Counts the current round and closes it.
    func settle() {
        fired += round.fired
        round = Round()
    }
}

/// The suite's entry: parses the arguments, runs a child-process entry or
/// the selected sections, and writes the report.
@MainActor
public func main(arguments: [String]) async {
    // A line at a time, so a run read through a pipe or a file shows each
    // row as it lands, and a trap loses nothing printed before it.
    setvbuf(stdout, nil, _IOLBF, 0)
    do {
        options = try Options(arguments: arguments)
    } catch {
        print("BatonBenchmarks: \(error)")
        exit(2)
    }
    if let (flag, path) = options.launch {
        if flag.hasPrefix("--anilist-launch") {
            await aniListLaunch(path, opened: flag == "--anilist-launch-opened")
        } else {
            await launch(path, opened: flag == "--launch-opened")
        }
        return
    }
    do {
        for _ in 0..<options.repeats { try await run() }
    } catch {
        print("BatonBenchmarks: \(error)")
        exit(1)
    }
    if options.profile != nil {
        print("BatonBenchmarks: no row's label contains \"\(options.profile!)\"")
        exit(2)
    }
    if let path = options.json {
        do {
            try suiteReport.json().write(to: URL(fileURLWithPath: path))
            if !options.countsOnly { print("report written to \(path)") }
        } catch {
            print("BatonBenchmarks: could not write \(path): \(error)")
            exit(1)
        }
    }
}
