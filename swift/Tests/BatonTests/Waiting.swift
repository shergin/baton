import Testing

/// Waits for `condition`, yielding to the tasks it depends on. When `timeout`
/// passes first, records an issue and returns false, so a test that waits for
/// something that never comes fails where it waited instead of hanging.
@MainActor
@discardableResult
func until(timeout: Duration = .seconds(10), _ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now > deadline {
            Issue.record("the condition did not hold within \(timeout)", sourceLocation: sourceLocation)
            return false
        }
        await Task.yield()
    }
    return true
}
