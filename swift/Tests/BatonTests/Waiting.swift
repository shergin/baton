import Testing

/// Waits for `condition`, yielding to the tasks it depends on, however long
/// a loaded machine takes to reach it: the main actor and the cooperative
/// pool are shared by every test running beside this one, so no wall-clock
/// budget a wait could name holds under load. A wait for something that
/// never comes ends at the suite's time limit, which cancels the test; the
/// wait then records an issue where it waited and returns false, so the test
/// fails there instead of hanging. `timeout` bounds a wait whose duration is
/// itself the claim, as a backoff's is.
@MainActor
@discardableResult
func until(timeout: Duration? = nil, _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    let start = ContinuousClock.now
    while !condition() {
        if Task.isCancelled {
            Issue.record("the test was cancelled before the condition held", sourceLocation: sourceLocation)
            return false
        }
        if let timeout, ContinuousClock.now - start > timeout {
            Issue.record("the condition did not hold within \(timeout)", sourceLocation: sourceLocation)
            return false
        }
        await Task.yield()
    }
    return true
}
