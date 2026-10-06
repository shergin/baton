@_spi(Generated) import Baton
import BatonTesting
import Foundation
import Observation
import Testing

@MainActor
@Suite("Phases", .timeLimit(.minutes(1)))
struct PhaseTests {
    /// A response about a character the operations below do not read, with
    /// nulls in it, so the store settles their phases again.
    func unrelatedCommit(_ store: Store) throws {
        store.commit(try Ingest.normalize(fixture("characters-7-nulls"), plan: TestList.plan.resolve(TestList(page: 3).variables)))
    }

    func settled<Op: Baton.Query>(_ handle: OperationHandle<Op>) async {
        await until { if case .loading = handle.phase { false } else { true } }
    }

    @Test("an error with no path fails an operation that throws, and an unrelated commit leaves it failed")
    func unplacedError() async throws {
        let environment = Environment(transport: RecordedTransport([TestStrictQuery.name: fixture("character-unplaced-error")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .failed(let error as FieldErrors) = handle.phase else {
            Issue.record("expected the unplaced error, got \(handle.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["rate limited"])
        try unrelatedCommit(environment.store)
        guard case .failed = handle.phase else {
            Issue.record("an unrelated commit made it \(handle.phase)")
            return
        }
        handle.release()
    }

    @Test("a root a @required field bubbled to fails with an error that names the operation and the path of the field that bubbled")
    func bubbledRootNamesTheField() async throws {
        let environment = Environment(transport: RecordedTransport([TestRequiredOrigin.name: fixture("required-origin-1-null")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestRequiredOrigin(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .failed(let error as RequiredFieldError) = handle.phase else {
            Issue.record("expected the required origin to fail the operation, got \(handle.phase)")
            return
        }
        #expect(error.operationName == TestRequiredOrigin.name)
        #expect(error.path == "character.origin")
        #expect(error.description == "TestRequiredOrigin: the @required field character.origin is null and bubbled to the root")
        #expect(RequiredFieldError(path: "character.origin").description == "the @required field character.origin is null")
        handle.release()

        let absent = Environment(transport: RecordedTransport([TestRequiredOrigin.name: fixture("character-null")]))
        absent.store.reportMissing = nil
        let root = absent.handle(for: TestRequiredOrigin(id: "1"))
        root.retain()
        await settled(root)
        guard case .failed(let rootError as RequiredFieldError) = root.phase else {
            Issue.record("expected the required character to fail the operation, got \(root.phase)")
            return
        }
        #expect(rootError.path == "character", "a null field at the root bubbles itself")
        root.release()
    }

    @Test("a root a @required(action: LOG) field bubbled to fails with the path of that field, and the environment is told of it and of the link it nulled")
    func loggedBubbledRootNamesTheField() async throws {
        let environment = Environment(transport: RecordedTransport([TestLoggedOrigin.name: fixture("required-origin-1-null")]))
        environment.store.reportMissing = nil
        var logged: [String] = []
        environment.requiredFieldMissing = { _, path in logged.append(path) }
        let handle = environment.handle(for: TestLoggedOrigin(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .failed(let error as RequiredFieldError) = handle.phase else {
            Issue.record("expected the required origin to fail the operation, got \(handle.phase)")
            return
        }
        #expect(error.path == "character.origin")
        #expect(Array(logged.prefix(2)) == ["character.origin", "character"])
        handle.release()
    }

    @Test("a bubbling failure is not assigned again when an unrelated commit evaluates it to the same @required path")
    func bubblingFailureIsNotReassigned() async throws {
        let environment = Environment(transport: RecordedTransport([TestRequiredOrigin.name: fixture("required-origin-1-null")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestRequiredOrigin(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .failed(let error) = handle.phase, error is RequiredFieldError else {
            Issue.record("expected the required origin to fail the operation, got \(handle.phase)")
            return
        }
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        withObservationTracking { _ = handle.phase } onChange: { counter.fired += 1 }
        try unrelatedCommit(environment.store)
        #expect(counter.fired == 0)
        handle.release()
    }

    @Test("an operation that failed on an error with no path fetches again when a view attaches it, and is ready once the error is gone")
    func unplacedErrorFetchesOnAttach() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in fixture(attempts.next() == 1 ? "character-unplaced-error" : "character-name-shown") }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .failed(let error as FieldErrors) = handle.phase else {
            Issue.record("expected the unplaced error, got \(handle.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["rate limited"])
        handle.release()

        // No record holds the error, so no commit clears it; a fetch does.
        let again = environment.handle(for: TestStrictQuery(id: "1"))
        #expect(again === handle)
        again.retain()
        await again.settle()
        #expect(transport.requestCount == 2)
        guard case .ready = again.phase else {
            Issue.record("expected ready, got \(again.phase)")
            return
        }
        again.release()
    }

    @Test("invalidate refetches a retained operation that failed on a field error, and the response that answers the field makes it ready")
    func invalidateRefetchesAFieldErrorFailure() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in fixture(attempts.next() == 1 ? "character-name-hidden" : "character-name-shown") }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .failed(let error) = handle.phase, error is FieldErrors else {
            Issue.record("expected the field error, got \(handle.phase)")
            return
        }
        #expect(!handle.isStale)
        environment.invalidate()
        #expect(handle.isStale, "the failure's data is in the store, and it predates the invalidation")
        await handle.settle()
        #expect(transport.requestCount == 2)
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        #expect(!handle.isStale)
        handle.release()
    }

    /// Fails `handle` on its first response, fetches it again with
    /// `refetch()`, or with `retry()` when `retrying`, and returns whether it
    /// was refreshing behind its failure while the fetch waited for the
    /// transport.
    func refreshingWhileItRefetches<Op: Baton.Query>(_ handle: OperationHandle<Op>, failingOn failure: Data, answeredBy answer: Data, through gate: GatedTransport, retrying: Bool = false) async -> Bool {
        handle.retain()
        defer { handle.release() }
        await until { gate.pending == 1 }
        gate.respond(failure)
        await settled(handle)
        guard case .failed = handle.phase else {
            Issue.record("expected a failure with its data in the store, got \(handle.phase)")
            return false
        }
        #expect(!handle.isRefreshing)
        let again: Task<Void, Never>
        if retrying {
            handle.retry()
            again = Task { await handle.settle() }
        } else {
            again = Task { try? await handle.refetch() }
        }
        await until { gate.pending == 1 }
        guard case .failed = handle.phase else {
            Issue.record("the failure and its data gave way to \(handle.phase)")
            return false
        }
        let refreshing = handle.isRefreshing
        gate.respond(answer)
        await again.value
        guard case .ready = handle.phase else {
            Issue.record("expected ready once the field is answered, got \(handle.phase)")
            return false
        }
        #expect(!handle.isRefreshing)
        return refreshing
    }

    @Test("a refetch of an operation failed with its data in the store, on a field error or on a @required null, is refreshing until its response lands")
    func aFailureWithDataRefreshes() async throws {
        let strict = GatedTransport()
        let environment = Environment(transport: strict)
        environment.store.reportMissing = nil
        #expect(await refreshingWhileItRefetches(environment.handle(for: TestStrictQuery(id: "1")), failingOn: fixture("character-name-hidden"), answeredBy: fixture("character-name-shown"), through: strict))

        let required = GatedTransport()
        let bubbling = Environment(transport: required)
        bubbling.store.reportMissing = nil
        #expect(await refreshingWhileItRefetches(bubbling.handle(for: TestRequiredOrigin(id: "1")), failingOn: fixture("required-origin-1-null"), answeredBy: fixture("required-origin-1"), through: required))
    }

    @Test("a retry of an operation failed with its data in the store, on a field error or on a @required null, keeps the failure in place and is refreshing until its response lands")
    func aRetryOfAFailureWithDataRefreshes() async throws {
        let strict = GatedTransport()
        let environment = Environment(transport: strict)
        environment.store.reportMissing = nil
        #expect(await refreshingWhileItRefetches(environment.handle(for: TestStrictQuery(id: "1")), failingOn: fixture("character-name-hidden"), answeredBy: fixture("character-name-shown"), through: strict, retrying: true))

        let required = GatedTransport()
        let bubbling = Environment(transport: required)
        bubbling.store.reportMissing = nil
        #expect(await refreshingWhileItRefetches(bubbling.handle(for: TestRequiredOrigin(id: "1")), failingOn: fixture("required-origin-1-null"), answeredBy: fixture("required-origin-1"), through: required, retrying: true))
    }

    @Test("a field error failure whose retry fails at the transport keeps its failure, and a commit that answers the field makes it ready")
    func failedRetryKeepsAFieldErrorFailure() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 1 ? fixture("character-name-hidden") : nil }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        defer { handle.release() }
        await settled(handle)
        handle.retry()
        await handle.settle()
        #expect(transport.requestCount == 2)
        guard case .failed(let error as FieldErrors) = handle.phase else {
            Issue.record("expected the field error the store still holds, got \(handle.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["name hidden"])
        let plan = TestStrictQuery.plan.resolve(TestStrictQuery(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("character-name-shown"), plan: plan))
        guard case .ready = handle.phase else {
            Issue.record("expected ready once a commit answers the field, got \(handle.phase)")
            return
        }
    }

    @Test("a handle that shows loading is not refreshing, though a refetch behind its ready data is in flight: not when a networkOnly view attaches over the refetch, nor when a fetch starts behind it")
    func loadingIsNotRefreshing() async throws {
        let gate = GatedTransport()
        let environment = Environment(transport: gate)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestList(page: 1))
        handle.retain()
        await until { gate.pending == 1 }
        gate.respond(fixtureData)
        await settled(handle)
        let first = Task { try? await handle.refetch() }
        await until { gate.pending == 1 }
        #expect(handle.isRefreshing)

        // A view that waits for its own response attaches while no one
        // shows the handle, which then shows loading, and refetches.
        handle.release()
        let waiting = environment.handle(for: TestList(page: 1), fetchPolicy: .networkOnly)
        #expect(waiting === handle)
        waiting.retain()
        defer { waiting.release() }
        guard case .loading = handle.phase else {
            Issue.record("expected loading until its own response, got \(handle.phase)")
            return
        }
        #expect(!handle.isRefreshing, "the refetch in flight is the view's own response")
        let second = Task { try? await handle.refetch() }
        await until { gate.pending == 2 }
        #expect(!handle.isRefreshing, "nothing shows behind loading")
        gate.respond(fixtureData)
        gate.respond(fixtureData)
        await first.value
        await second.value
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        #expect(!handle.isRefreshing)
    }

    @Test("a field error failure whose refetch fails at the transport keeps its failure, and a commit that answers the field makes it ready")
    func failedRefetchKeepsAFieldErrorFailure() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 1 ? fixture("character-name-hidden") : nil }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        defer { handle.release() }
        await settled(handle)
        environment.invalidate()
        await handle.settle()
        #expect(transport.requestCount == 2)
        guard case .failed(let error as FieldErrors) = handle.phase else {
            Issue.record("expected the field error the store still holds, got \(handle.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["name hidden"])
        #expect(handle.isStale, "no response replaced the data the invalidation made stale")
        let plan = TestStrictQuery.plan.resolve(TestStrictQuery(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("character-name-shown"), plan: plan))
        guard case .ready = handle.phase else {
            Issue.record("expected ready once a commit answers the field, got \(handle.phase)")
            return
        }
    }

    @Test("a parked field error failure whose refetch failed at the transport is ready when attached again over the answered field, and fetches because it is stale")
    func failedRefetchOfAFieldErrorFailureSettlesOnAttach() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 1 ? fixture("character-name-hidden") : nil }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await settled(handle)
        environment.invalidate()
        await handle.settle()
        handle.release()
        let plan = TestStrictQuery.plan.resolve(TestStrictQuery(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("character-name-shown"), plan: plan))

        let again = environment.handle(for: TestStrictQuery(id: "1"))
        #expect(again === handle)
        again.retain()
        defer { again.release() }
        guard case .ready = again.phase else {
            Issue.record("expected ready over the answered field, got \(again.phase)")
            return
        }
        await again.settle()
        #expect(transport.requestCount == 3)
    }

    @Test("a failed phase is not assigned again when an unrelated commit evaluates it to the same failure")
    func failureIsNotReassigned() async throws {
        let environment = Environment(transport: RecordedTransport([TestStrictQuery.name: fixture("character-name-hidden")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .failed = handle.phase else {
            Issue.record("expected a failure, got \(handle.phase)")
            return
        }
        final class Counter: @unchecked Sendable { var fired = 0 }
        let counter = Counter()
        withObservationTracking { _ = handle.phase } onChange: { counter.fired += 1 }
        try unrelatedCommit(environment.store)
        #expect(counter.fired == 0)
        handle.release()
    }

    @Test("a refetch of an operation that throws throws the field error its response put in the operation's own selection")
    func refetchThrowsFieldErrors() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in fixture(attempts.next() == 1 ? "character-name-shown" : "character-name-hidden") }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        let thrown = await #expect(throws: FieldErrors.self) { try await handle.refetch() }
        #expect(thrown?.errors.map(\.message) == ["name hidden"])
        guard case .failed(let error) = handle.phase, error is FieldErrors else {
            Issue.record("expected the field error, got \(handle.phase)")
            return
        }
        handle.release()
    }

    @Test("a preload's fetch serves the first attach only while its data is fresh")
    func preloadThenInvalidate() async throws {
        let transport = RecordedTransport([TestList.name: fixtureData])
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let preloaded = environment.preload(TestList(page: 1))
        await settled(preloaded)
        #expect(transport.requestCount == 1)
        environment.invalidate()
        let handle = environment.handle(for: TestList(page: 1), fetchPolicy: .storeOrNetwork)
        await until { transport.requestCount == 2 }
        #expect(transport.requestCount == 2, "the data went stale after the preload")
        handle.retain()
        handle.release()
    }

    @Test("a preload's fresh data serves the first attach by the commits since: one that put a field error or a null into its selection fails it")
    func preloadSettlesOnTheFirstAttach() async throws {
        let transport = RecordedTransport([TestStrictQuery.name: fixture("character-name-shown"), TestRequiredOrigin.name: fixture("required-origin-1")])
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let strict = environment.preload(TestStrictQuery(id: "1"))
        let bubbling = environment.preload(TestRequiredOrigin(id: "1"))
        await strict.settle()
        await bubbling.settle()
        guard case .ready = strict.phase, case .ready = bubbling.phase else {
            Issue.record("expected both preloads ready, got \(strict.phase) and \(bubbling.phase)")
            return
        }
        // Parked, the preloaded handles are settled by no commit before
        // their first attach.
        environment.store.commit(try Ingest.normalize(fixture("character-name-hidden"), plan: TestStrictQuery.plan.resolve(TestStrictQuery(id: "1").variables)))
        environment.store.commit(try Ingest.normalize(fixture("required-origin-1-null"), plan: TestRequiredOrigin.plan.resolve(TestRequiredOrigin(id: "1").variables)))

        let attached = environment.handle(for: TestStrictQuery(id: "1"))
        #expect(attached === strict)
        if case .failed(let error as FieldErrors) = attached.phase {
            #expect(error.errors.map(\.message) == ["name hidden"])
        } else {
            Issue.record("expected the committed error, got \(attached.phase)")
        }
        let bubbled = environment.handle(for: TestRequiredOrigin(id: "1"))
        #expect(bubbled === bubbling)
        if case .failed(let error) = bubbled.phase {
            #expect(error is RequiredFieldError)
        } else {
            Issue.record("expected the required origin to fail the operation, got \(bubbled.phase)")
        }
        #expect(transport.requestCount == 2, "the preloads' fetches served the attaches")
    }

    @Test("a preload that sent nothing serves no attach: a later networkOnly attach fetches")
    func preloadWithoutAFetch() async throws {
        let transport = RecordedTransport([TestList.name: fixtureData])
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let first = environment.handle(for: TestList(page: 1))
        first.retain()
        await settled(first)
        first.release()
        #expect(transport.requestCount == 1)
        _ = environment.preload(TestList(page: 1), fetchPolicy: .storeOrNetwork)
        #expect(transport.requestCount == 1, "the store had the data, fresh")
        _ = environment.handle(for: TestList(page: 1), fetchPolicy: .networkOnly)
        await until { transport.requestCount == 2 }
        #expect(transport.requestCount == 2)
    }

    @Test("a parked handle that failed on a field error is ready when attached again after the error cleared")
    func parkedFailureClears() async throws {
        let environment = Environment(transport: RecordedTransport([TestStrictQuery.name: fixture("character-name-hidden")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"), fetchPolicy: .storeOrNetwork)
        handle.retain()
        await settled(handle)
        handle.release()
        guard case .failed = handle.phase else {
            Issue.record("expected a failure, got \(handle.phase)")
            return
        }
        // Another operation answers the name while the handle is parked.
        let plan = TestProfileQuery.plan.resolve(TestProfileQuery(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("character-deferred-1"), plan: plan))
        let again = environment.handle(for: TestStrictQuery(id: "1"), fetchPolicy: .storeOnly)
        #expect(again === handle)
        guard case .ready = again.phase else {
            Issue.record("expected ready, got \(again.phase)")
            return
        }
    }

    @Test("a parked handle that was ready fails when attached again after a commit put a field error in its selection")
    func parkedReadyHandleFails() async throws {
        let environment = Environment(transport: RecordedTransport([TestStrictQuery.name: fixture("character-name-shown")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictQuery(id: "1"))
        handle.retain()
        await settled(handle)
        handle.release()
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        // A parked handle is settled by no commit until a view attaches it.
        let plan = TestStrictQuery.plan.resolve(TestStrictQuery(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("character-name-hidden"), plan: plan))
        let again = environment.handle(for: TestStrictQuery(id: "1"), fetchPolicy: .storeOnly)
        #expect(again === handle)
        guard case .failed(let error as FieldErrors) = again.phase else {
            Issue.record("expected the committed error, got \(again.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["name hidden"])
    }

    @Test("a parked bubbling handle that was ready fails when attached again after a commit nulled a field it requires")
    func parkedReadyHandleBubbles() async throws {
        let environment = Environment(transport: RecordedTransport([TestRequiredOrigin.name: fixture("required-origin-1")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestRequiredOrigin(id: "1"))
        handle.retain()
        await settled(handle)
        handle.release()
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        let plan = TestRequiredOrigin.plan.resolve(TestRequiredOrigin(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("required-origin-1-null"), plan: plan))
        let again = environment.handle(for: TestRequiredOrigin(id: "1"), fetchPolicy: .storeOnly)
        #expect(again === handle)
        guard case .failed(let error) = again.phase, error is RequiredFieldError else {
            Issue.record("expected the required origin to fail the operation, got \(again.phase)")
            return
        }
    }

    @Test("the first part of a deferred response fails an operation that throws on the error with no path it carried, and the operation stays failed whether the stream completes or breaks")
    func deferredFirstPartFails() async throws {
        for completes in [true, false] {
            let transport = DeliveryTests.GatedParts(fixture("strict-deferred-1-unplaced-error"), fixture("strict-deferred-2"))
            let environment = Environment(transport: transport)
            environment.store.reportMissing = nil
            let handle = environment.handle(for: TestStrictDeferred(id: "1"))
            handle.retain()
            await settled(handle)
            guard case .failed(let error as FieldErrors) = handle.phase else {
                Issue.record("expected the first part's error, got \(handle.phase)")
                return
            }
            #expect(error.errors.map(\.message) == ["rate limited"])
            if completes { transport.release() } else { transport.fail() }
            await handle.settle()
            guard case .failed = handle.phase else {
                Issue.record("expected the operation to stay failed, got \(handle.phase)")
                return
            }
            handle.release()
        }
    }

    @Test("a deferred refetch whose first part carries no error makes a failed operation that throws ready before the rest arrives")
    func deferredFirstPartClears() async throws {
        let transport = LifetimeTests.ManualStreams()
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictDeferred(id: "1"))
        handle.retain()
        await until { transport.count == 1 }
        transport.deliver(fixture("strict-deferred-1-unplaced-error"), to: 0)
        transport.deliver(fixture("strict-deferred-2"), to: 0)
        await handle.settle()
        guard case .failed(let error as FieldErrors) = handle.phase else {
            Issue.record("expected the unplaced error, got \(handle.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["rate limited"])

        let refetch = Task { try await handle.refetch() }
        await until { transport.count == 2 }
        transport.deliver(fixture("strict-deferred-1"), to: 1)
        await until { if case .ready = handle.phase { true } else { false } }
        transport.deliver(fixture("strict-deferred-2"), to: 1)
        try await refetch.value
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        handle.release()
    }

    @Test("a commit that moves a link onto a record with a field error fails an operation that throws and reads through it")
    func movedLink() async throws {
        let environment = Environment(transport: RecordedTransport([TestStrictOrigin.name: fixture("strict-origin-1")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictOrigin(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        let other = TestStrictOrigin.plan.resolve(TestStrictOrigin(id: "2").variables)
        environment.store.commit(try Ingest.normalize(fixture("strict-origin-2-hidden"), plan: other))
        guard case .ready = handle.phase else {
            Issue.record("another character's origin is not in the selection, got \(handle.phase)")
            return
        }
        let own = TestStrictOrigin.plan.resolve(TestStrictOrigin(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("strict-origin-1-moved"), plan: own))
        guard case .failed(let error as FieldErrors) = handle.phase else {
            Issue.record("expected the moved-in error, got \(handle.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["name hidden"])
        handle.release()
    }

    @Test("a commit that swaps a list of links onto a record with a field error fails an operation that throws and reads through it")
    func movedLinks() async throws {
        let environment = Environment(transport: RecordedTransport([TestStrictEpisodes.name: fixture("strict-episodes-1")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestStrictEpisodes(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        let other = TestStrictEpisodes.plan.resolve(TestStrictEpisodes(id: "2").variables)
        environment.store.commit(try Ingest.normalize(fixture("strict-episodes-2-hidden"), plan: other))
        guard case .ready = handle.phase else {
            Issue.record("another character's episodes are not in the selection, got \(handle.phase)")
            return
        }
        // The list is all the commit changes: the episode it links to holds
        // the error already.
        let own = TestStrictEpisodes.plan.resolve(TestStrictEpisodes(id: "1").variables)
        environment.store.commit(try Ingest.normalize(fixture("strict-episodes-1-moved"), plan: own))
        guard case .failed(let error as FieldErrors) = handle.phase else {
            Issue.record("expected the moved-in error, got \(handle.phase)")
            return
        }
        #expect(error.errors.map(\.message) == ["name hidden"])
        handle.release()
    }

    @Test("a bubbling operation fails when another commit nulls a field it requires, with no error on it")
    func nullFailsABubblingOperation() async throws {
        let environment = Environment(transport: RecordedTransport([TestRequiredOrigin.name: fixture("required-origin-1")]))
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestRequiredOrigin(id: "1"))
        handle.retain()
        await settled(handle)
        guard case .ready = handle.phase else {
            Issue.record("expected ready, got \(handle.phase)")
            return
        }
        environment.store.commit(try Ingest.normalize(fixture("required-origin-1-null"), plan: TestRequiredOrigin.plan.resolve(TestRequiredOrigin(id: "1").variables)))
        guard case .failed(let error) = handle.phase, error is RequiredFieldError else {
            Issue.record("expected the required origin to fail the operation, got \(handle.phase)")
            return
        }
        handle.release()
    }

    @Test("every public error's localized description is the description it carries")
    func localizedDescriptions() async throws {
        var errors: [any Error & CustomStringConvertible] = [
            FieldError(message: "rate limited", path: "character.name"),
            FieldErrors([FieldError(message: "rate limited", path: "character.name"), FieldError(message: "gone", path: "")]),
            RequiredFieldError(path: "character.name"),
            EnvironmentError.notInjected,
            EnvironmentError.outsideEnvironment,
            EnvironmentError.gone,
            EnvironmentError.noSubscriptionTransport,
            GraphQLErrors(messages: ["not found", "rate limited"]),
            TransportError(statusCode: 503, body: "unavailable"),
            TransportError(statusCode: 0, body: "the socket closed"),
        ]

        // The two without a public initializer, provoked: a response cut
        // off mid-way, and a store-only read of data never fetched.
        let plan = TestList.plan.resolve(TestList(page: 1).variables)
        do {
            _ = try Ingest.normalize(fixtureData.prefix(40), plan: plan)
            Issue.record("expected the cut-off response to fail")
        } catch let error as IngestError {
            errors.append(error)
        }
        let environment = Environment(transport: SilentTransport())
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestHeaderQuery(id: "1"), fetchPolicy: .storeOnly)
        guard case .failed(let missing as MissingDataError) = handle.phase else {
            Issue.record("expected missing data, got \(handle.phase)")
            return
        }
        errors.append(missing)

        for error in errors {
            #expect(error.localizedDescription == error.description)
        }
        #expect(errors.count == 12)
    }

    @Test("a refetch that fails at the transport behind ready data leaves the phase ready, records the transport's error and when, and the next successful refetch reads idle again")
    func aTransportFailureBehindDataIsReadBesideThePhase() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 2 ? nil : fixtureData }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestList(page: 1))
        handle.retain()
        defer { handle.release() }
        await settled(handle)
        guard case .idle = handle.fetch else {
            Issue.record("expected an idle fetch after the first response, got \(handle.fetch)")
            return
        }

        let before = ContinuousClock.now
        let thrown = await #expect(throws: TransportError.self) { try await handle.refetch() }
        #expect(thrown?.statusCode == 0, "the refetch throws the error as the transport threw it")
        guard case .ready = handle.phase else {
            Issue.record("the data stays visible, got \(handle.phase)")
            return
        }
        guard case .failed(.transport(let error as TransportError), let instant) = handle.fetch else {
            Issue.record("expected a transport failure, got \(handle.fetch)")
            return
        }
        #expect(error.statusCode == thrown?.statusCode)
        #expect(error.body == thrown?.body)
        #expect(instant >= before)
        #expect(instant <= .now)
        #expect(handle.fetch.failure?.error is TransportError)
        #expect(!handle.isRefreshing)

        try await handle.refetch()
        #expect(transport.requestCount == 3)
        guard case .ready = handle.phase, case .idle = handle.fetch else {
            Issue.record("expected ready and an idle fetch after a successful refetch, got \(handle.phase) and \(handle.fetch)")
            return
        }
        #expect(handle.fetch.failure == nil)
    }

    @Test("a fetch that fails with no data to show fails the phase with the error as thrown and the fetch with the same error, and a retry shows loading in flight until a response makes it ready and idle")
    func aFailureWithoutDataFailsThePhaseAndTheFetch() async throws {
        let attempts = Attempts()
        let transport = RecordedTransport { _ in attempts.next() == 1 ? nil : fixtureData }
        let environment = Environment(transport: transport)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestList(page: 1))
        handle.retain()
        defer { handle.release() }
        await settled(handle)
        guard case .failed(let thrown as TransportError) = handle.phase else {
            Issue.record("expected the transport's error, got \(handle.phase)")
            return
        }
        guard case .failed(.transport(let recorded as TransportError), _) = handle.fetch else {
            Issue.record("expected a transport failure, got \(handle.fetch)")
            return
        }
        #expect(recorded.body == thrown.body)
        #expect(!handle.isRefreshing)

        handle.retry()
        guard case .loading = handle.phase, case .inFlight = handle.fetch else {
            Issue.record("expected loading and a fetch in flight, got \(handle.phase) and \(handle.fetch)")
            return
        }
        #expect(!handle.isRefreshing, "nothing shows behind loading")
        await handle.settle()
        guard case .ready = handle.phase, case .idle = handle.fetch else {
            Issue.record("expected ready and an idle fetch, got \(handle.phase) and \(handle.fetch)")
            return
        }
    }

    @Test("a fetch's failure is classified: errors and no data are a request failure, a response the plan cannot read is malformed, and a handle whose environment is gone fails on the environment")
    func failureKinds() async throws {
        let refused = Environment(transport: RecordedTransport([TestProfileQuery.name: fixture("not-authorized")]))
        let request = refused.handle(for: TestProfileQuery(id: "1"))
        request.retain()
        await request.settle()
        if case .failed(.request(let errors), _) = request.fetch {
            #expect(errors.messages == ["not authorized"])
        } else {
            Issue.record("expected a request failure, got \(request.fetch)")
        }
        if case .failed(let error) = request.phase {
            #expect(error is GraphQLErrors)
        } else {
            Issue.record("expected the phase to fail on the errors, got \(request.phase)")
        }
        request.release()

        let truncated = Environment(transport: RecordedTransport([TestList.name: fixtureData.prefix(40)]))
        truncated.store.reportMissing = nil
        let malformed = truncated.handle(for: TestList(page: 1))
        malformed.retain()
        await malformed.settle()
        if case .failed(.malformed, _) = malformed.fetch {
            #expect(malformed.fetch.failure?.error is IngestError)
        } else {
            Issue.record("expected a malformed response, got \(malformed.fetch)")
        }
        if case .failed(let error) = malformed.phase {
            #expect(error is IngestError)
        } else {
            Issue.record("expected the phase to fail on the response, got \(malformed.phase)")
        }
        malformed.release()

        var environment: Baton.Environment? = Baton.Environment(transport: SilentTransport())
        environment!.store.commit(try Ingest.normalize(fixtureData, plan: TestList.plan.resolve(TestList(page: 1).variables)))
        let orphan = environment!.handle(for: TestList(page: 1), fetchPolicy: .storeOnly)
        orphan.retain()
        environment = nil
        try await orphan.refetch()
        guard case .ready = orphan.phase else {
            Issue.record("the data stays visible, got \(orphan.phase)")
            return
        }
        if case .failed(.environment(let error), _) = orphan.fetch {
            #expect(error == .gone)
        } else {
            Issue.record("expected the environment it lost, got \(orphan.fetch)")
        }
        #expect(!orphan.isRefreshing)
        orphan.release()
    }

    /// A recorded response with one member taken out, as a server that
    /// skipped a field would send it.
    func omitting(_ member: String, from data: Data) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
        try #require(text.contains(member), "the fixture carries \(member)")
        return Data(text.replacingOccurrences(of: member, with: "").utf8)
    }

    @Test("a response that omits a scalar or a linked field the operation selected is malformed: the phase fails with an ingest error naming the field and its type, and the fetch reads malformed")
    func aResponseThatOmitsASelectedFieldIsMalformed() async throws {
        let header = fixture("character-header-5")
        let omissions = [
            (#""species":"Human","#, "the response omits `species` of `Character`, which the operation selected"),
            (#""origin":{"name":"Earth (Replacement Dimension)","id":"20"},"#, "the response omits `origin` of `Character`, which the operation selected"),
        ]
        for (member, message) in omissions {
            let environment = Environment(transport: RecordedTransport([TestHeaderQuery.name: try omitting(member, from: header)]))
            environment.store.reportMissing = nil
            let handle = environment.handle(for: TestHeaderQuery(id: "5"))
            handle.retain()
            await handle.settle()
            guard case .failed(let error as IngestError) = handle.phase else {
                Issue.record("expected the phase to fail on the response, got \(handle.phase)")
                handle.release()
                continue
            }
            #expect(error.message == message)
            guard case .failed(.malformed(let recorded), _) = handle.fetch else {
                Issue.record("expected a malformed response, got \(handle.fetch)")
                handle.release()
                continue
            }
            #expect(recorded.message == message)
            handle.release()
        }
    }

    @Test("a response that answers every field the operation selected, some with null, is complete, and so is one that omits the __typename the compiler added to an abstract selection")
    func aResponseThatAnswersEveryFieldIsComplete() async throws {
        let answered = fixture("search-origins-1")
        let untyped = try omitting(#","__typename":"Character""#, from: try omitting(#""__typename":"Character","#, from: answered))
        for (response, typed) in [(answered, true), (untyped, false)] {
            let environment = Environment(transport: RecordedTransport([TestSearchOrigins.name: response]))
            environment.store.reportMissing = nil
            let handle = environment.handle(for: TestSearchOrigins(name: "a"))
            handle.retain()
            await handle.settle()
            guard case .ready = handle.phase, case .idle = handle.fetch else {
                Issue.record("expected ready and an idle fetch, got \(handle.phase) and \(handle.fetch)")
                handle.release()
                continue
            }
            // Without `__typename` the record is keyed by the abstract type,
            // since nothing names the concrete one.
            #expect((environment.store.existing("Character:2") != nil) == typed)
            handle.release()
        }
    }

    @Test("a fetch in flight reads in flight behind loading and behind ready data, and refreshing only behind the data")
    func aFetchInFlightReadsInFlight() async throws {
        let gate = GatedTransport()
        let environment = Environment(transport: gate)
        environment.store.reportMissing = nil
        let handle = environment.handle(for: TestList(page: 1))
        handle.retain()
        defer { handle.release() }
        await until { gate.pending == 1 }
        guard case .loading = handle.phase, case .inFlight = handle.fetch else {
            Issue.record("expected loading and a fetch in flight, got \(handle.phase) and \(handle.fetch)")
            return
        }
        #expect(!handle.isRefreshing, "nothing shows behind loading")
        gate.respond(fixtureData)
        await settled(handle)
        guard case .idle = handle.fetch else {
            Issue.record("expected an idle fetch after the response, got \(handle.fetch)")
            return
        }

        let refetch = Task { try? await handle.refetch() }
        await until { gate.pending == 1 }
        guard case .ready = handle.phase, case .inFlight = handle.fetch else {
            Issue.record("expected ready data and a fetch in flight, got \(handle.phase) and \(handle.fetch)")
            return
        }
        #expect(handle.isRefreshing)
        gate.respond(fixtureData)
        await refetch.value
        guard case .idle = handle.fetch else {
            Issue.record("expected an idle fetch after the response, got \(handle.fetch)")
            return
        }
        #expect(!handle.isRefreshing)
    }

    @Test("a query value reads its handle's fetch once resolved, and an idle fetch before")
    func aQueryValueReadsTheFetch() async throws {
        let gate = GatedTransport()
        let environment = Environment(transport: gate)
        environment.store.reportMissing = nil
        var operation = TestList(page: 1)
        guard case .idle = operation.fetch else {
            Issue.record("expected an unresolved value to read idle, got \(operation.fetch)")
            return
        }
        let handle = environment.handle(for: operation)
        handle.retain()
        defer { handle.release() }
        operation.resolution = handle
        await until { gate.pending == 1 }
        gate.respond(fixtureData)
        await settled(handle)

        let refetch = Task { try? await handle.refetch() }
        await until { gate.pending == 1 }
        guard case .inFlight = operation.fetch else {
            Issue.record("expected the value to read the fetch in flight, got \(operation.fetch)")
            return
        }
        #expect(operation.isRefreshing)
        gate.fail(URLError(.notConnectedToInternet))
        await refetch.value
        guard case .ready = operation.phase else {
            Issue.record("the data stays visible, got \(operation.phase)")
            return
        }
        guard case .failed(.transport(let error as URLError), _) = operation.fetch else {
            Issue.record("expected the value to read the transport's failure, got \(operation.fetch)")
            return
        }
        #expect(error.code == .notConnectedToInternet)
        #expect(!operation.isRefreshing)
    }
}
