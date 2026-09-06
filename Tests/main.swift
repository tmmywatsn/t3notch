import Foundation

var failures = 0

func expect(_ actual: some Equatable, _ expected: some Equatable, _ what: String) {
    if "\(actual)" == "\(expected)" {
        print("  ok   \(what)")
    } else {
        print("  FAIL \(what): expected \(expected), got \(actual)")
        failures += 1
    }
}

func run(_ name: String, _ body: () -> Void) {
    print(name)
    body()
}

/// A thread with nothing going on, for tests to vary one field at a time.
func makeRun(
    status: SessionStatus = .ready,
    turnState: String? = nil,
    approvals: Int = 0,
    questions: Int = 0,
    plan: Bool = false,
    started: Date = Date(timeIntervalSince1970: 0)
) -> AgentRun {
    AgentRun(
        id: "t", title: "t", projectID: "p", projectTitle: "p", branch: nil,
        status: status, provider: nil, model: nil, activeTurnID: nil, lastError: nil,
        turnStartedAt: started, turnState: turnState,
        pendingApprovals: approvals, pendingQuestions: questions,
        hasActionablePlan: plan, updatedAt: started
    )
}

run("ThreadPhase follows T3 Code's precedence") {
    expect(makeRun(status: .running, approvals: 1).phase, ThreadPhase.waitingForApproval,
           "approvals outrank everything")
    expect(makeRun(status: .running, questions: 1).phase, ThreadPhase.waitingForInput,
           "questions outrank a running session")
    expect(makeRun(status: .error).phase, ThreadPhase.failed, "session error is a failure")
    expect(makeRun(status: .ready, turnState: "error").phase, ThreadPhase.failed,
           "turn error is a failure too")
    expect(makeRun(status: .starting).phase, ThreadPhase.starting, "starting is its own phase")
    expect(makeRun(status: .ready, turnState: "running").phase, ThreadPhase.running,
           "a running turn counts even when the session says ready")
    expect(makeRun(status: .ready, turnState: "completed").phase, ThreadPhase.completed, "completed")
    expect(makeRun(status: .stopped).phase, ThreadPhase.stale, "nothing known is stale")
    expect(SessionStatus(rawValue: "no-such-status") ?? .unknown, SessionStatus.unknown,
           "an unrecognised status degrades rather than crashes")
}

run("A thread is never both working and waiting") {
    let waiting = makeRun(status: .running, questions: 1)
    expect(waiting.isWorking, false, "waiting on you is not working")
    expect(waiting.needsAttention, true, "waiting on you needs attention")
    let working = makeRun(status: .running)
    expect(working.isWorking, true, "running is working")
    expect(working.needsAttention, false, "running alone needs nothing")
    expect(makeRun(status: .ready, plan: true).needsAttention, true, "an idle plan needs review")
    expect(makeRun(status: .running, plan: true).needsAttention, false,
           "a plan while working can wait")
}

run("Context window thresholds") {
    expect(ContextWindow(used: 79, max: 100).isWarning, false, "79% is quiet")
    expect(ContextWindow(used: 80, max: 100).isWarning, true, "80% warns")
    expect(ContextWindow(used: 92, max: 100).isCritical, true, "92% is critical")
    expect(ContextWindow(used: 10, max: 0).fraction, 0.0, "a zero maximum doesn't divide by zero")
}

run("Durations read the way a human would say them") {
    expect((0.94).runDuration, "940ms", "sub-second")
    expect((45.0).runDuration, "45s", "seconds")
    expect((134.0).runDuration, "2m 14s", "minutes")
    expect((3780.0).runDuration, "1h 03m", "hours")
}

run("Single-line clipping") {
    expect("a\n  b\tc".singleLine(), "a b c", "whitespace collapses")
    expect(String(repeating: "x", count: 10).singleLine(limit: 4), "xxxx…", "long text is clipped")
}

run("Relative times") {
    let now = Date(timeIntervalSince1970: 100_000)
    expect(now.addingTimeInterval(-30).ago(from: now), "just now", "under a minute")
    expect(now.addingTimeInterval(-600).ago(from: now), "10m ago", "minutes")
    expect(now.addingTimeInterval(-7200).ago(from: now), "2h ago", "hours")
}

run("Versions compare as numbers, not text") {
    expect(AppVersion("1.10.0")! > AppVersion("1.9.0")!, true, "1.10.0 beats 1.9.0")
    expect(AppVersion("2.0.0")! > AppVersion("1.99.99")!, true, "a major bump wins")
    expect(AppVersion("1.2")! == AppVersion("1.2.0")!, true, "a missing patch reads as zero")
    expect(AppVersion("1.2.0")! > AppVersion("1.2.0")!, false, "the same version is not newer")
    expect(AppVersion("v1.2.0")!.description, "1.2.0", "a leading v is dropped")
    expect(AppVersion("1.2.0-beta.1")!.description, "1.2.0", "a pre-release suffix is ignored")
    expect(AppVersion("") == nil, true, "empty is not a version")
    expect(AppVersion("nightly") == nil, true, "words are not a version")
    expect(AppVersion("1.2.x") == nil, true, "a non-numeric component is rejected")
    expect(AppVersion("-1.0") == nil, true, "a negative component is rejected")
}

run("Update responses are only trusted when they should be") {
    let current = AppVersion("1.0.0")!
    let url = URL(string: "https://api.github.com")!
    func reply(_ status: Int, _ json: String) -> (Data?, URLResponse?) {
        (json.data(using: .utf8),
         HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil))
    }

    let (newer, ok) = reply(200, #"{"tag_name":"v1.1.0","html_url":"https://example.com/r"}"#)
    expect(
        UpdateChecker.parse(data: newer, response: ok, error: nil, current: current)?.version.description ?? "none",
        "1.1.0",
        "a newer tag is offered"
    )

    let (same, ok2) = reply(200, #"{"tag_name":"v1.0.0","html_url":"https://example.com/r"}"#)
    expect(
        UpdateChecker.parse(data: same, response: ok2, error: nil, current: current) == nil,
        true,
        "the running version is not an update"
    )

    let (older, ok3) = reply(200, #"{"tag_name":"v0.9.0","html_url":"https://example.com/r"}"#)
    expect(
        UpdateChecker.parse(data: older, response: ok3, error: nil, current: current) == nil,
        true,
        "an older tag is ignored"
    )

    let (draft, ok4) = reply(200, #"{"tag_name":"v2.0.0","draft":true}"#)
    expect(
        UpdateChecker.parse(data: draft, response: ok4, error: nil, current: current) == nil,
        true,
        "a draft is ignored"
    )

    let (pre, ok5) = reply(200, #"{"tag_name":"v2.0.0","prerelease":true}"#)
    expect(
        UpdateChecker.parse(data: pre, response: ok5, error: nil, current: current) == nil,
        true,
        "a pre-release is ignored"
    )

    let (rateLimited, tooMany) = reply(403, #"{"tag_name":"v9.9.9"}"#)
    expect(
        UpdateChecker.parse(data: rateLimited, response: tooMany, error: nil, current: current) == nil,
        true,
        "a non-200 body is not read"
    )

    let (garbage, ok6) = reply(200, "not json")
    expect(
        UpdateChecker.parse(data: garbage, response: ok6, error: nil, current: current) == nil,
        true,
        "malformed JSON is survivable"
    )

    let (fine, ok7) = reply(200, #"{"tag_name":"v1.1.0"}"#)
    expect(
        UpdateChecker.parse(data: fine, response: ok7,
                            error: URLError(.notConnectedToInternet), current: current) == nil,
        true,
        "a transport error wins over the body"
    )

    let (noURL, ok8) = reply(200, #"{"tag_name":"v1.1.0"}"#)
    expect(
        UpdateChecker.parse(data: noURL, response: ok8, error: nil, current: current)?.page.absoluteString ?? "none",
        "https://github.com/tmmywatsn/t3notch/releases/latest",
        "a missing page URL falls back to the releases page"
    )
}

print("")
if failures == 0 {
    print("all tests passed")
} else {
    print("\(failures) test(s) failed")
    exit(1)
}
