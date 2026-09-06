import Foundation
import SQLite3

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

// Exercise the same SQLite → reader → store path used by the running notch.
run("Subagent handoff keeps the parent visible until all work settles") {
    MainActor.assumeIsolated {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let setup = Process()
        setup.executableURL = URL(fileURLWithPath: "/bin/bash")
        setup.arguments = ["Scripts/fixture.sh", "setup"]
        setup.environment = ProcessInfo.processInfo.environment.merging(["T3NOTCH_FIXTURE": directory.path]) { _, new in new }
        setup.standardOutput = FileHandle.nullDevice
        try! setup.run()
        setup.waitUntilExit()
        expect(setup.terminationStatus, 0, "fixture created")
        var handle: OpaquePointer?
        precondition(sqlite3_open(directory.appendingPathComponent("state.sqlite").path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        func sql(_ statement: String) {
            precondition(sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK)
        }
        let database = try! T3Database(path: directory.appendingPathComponent("state.sqlite").path)
        defer { database.close() }
        let reader = T3Reader()
        let store = T3Store()
        var events: [NotchEvent] = []
        store.onEvent = { events.append($0) }
        let time = Date()
        @MainActor func refresh(_ seconds: Double) {
            store.apply(try! reader.snapshot(from: database, focusLimit: 6), at: time.addingTimeInterval(seconds))
        }
        sql("""
            UPDATE projection_thread_sessions SET status='running', active_turn_id='turn1';
            INSERT INTO projection_turns (thread_id,turn_id,state,requested_at,started_at,checkpoint_files_json)
              VALUES ('t1','turn1','running','2026-09-06T00:00:00Z','2026-09-06T00:00:00Z','[]');
            """)
        refresh(0)
        sql("""
            UPDATE projection_thread_sessions SET status='ready', active_turn_id=NULL;
            UPDATE projection_turns SET state='completed', completed_at='2026-09-06T00:01:00Z';
            """)
        refresh(1)
        expect(store.runningCount, 1, "handoff gap keeps the parent in the working view")
        expect(events.count, 0, "handoff gap does not announce completion")
        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('start','t1','turn1','info','task.started','Agent started',
               '{"taskId":"child","taskType":"local_agent"}','2026-09-06T00:01:01Z',1);
            """)
        refresh(2)
        refresh(30)
        expect(store.runningCount, 1, "child work keeps the settled parent visible beyond the grace period")
        expect(events.count, 0, "active child does not announce completion")
        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('done','t1','turn1','info','task.completed','Agent completed',
               '{"taskId":"child","status":"completed"}','2026-09-06T00:02:00Z',2);
            """)
        refresh(60)
        store.tick(at: time.addingTimeInterval(64))
        expect(store.runningCount, 0, "timer settles the parent without another database write")
        expect(events.count, 1, "completion is announced once after all work settles")
        refresh(65)
        expect(events.count, 1, "unchanged snapshots do not repeat completion")

        // Real providers can omit sequence; lifecycle ordering must still work.
        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('a','t1','turn1','info','task.started','Agent A','{"taskId":"a"}','2026-09-06T00:03:00Z',NULL),
              ('b','t1','turn1','info','task.started','Agent B','{"taskId":"b"}','2026-09-06T00:03:01Z',NULL);
            INSERT INTO projection_turns (thread_id,turn_id,state,requested_at,started_at,completed_at,checkpoint_files_json)
              VALUES ('t1','turn2','completed','2026-09-06T00:03:02Z','2026-09-06T00:03:02Z','2026-09-06T00:03:03Z','[]');
            """)
        for index in 0..<45 {
            sql("INSERT INTO projection_thread_activities VALUES ('noise\(index)','t1','turn2','info','tool.completed','Tool finished','{}','2026-09-06T00:04:00Z',\(index+10))")
        }
        refresh(70)
        expect(store.runningCount, 1, "older-turn children remain live beyond the UI activity limit")
        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('idle','t1','turn1','info','task.updated','Agent A idle','{"taskId":"a","status":"idle"}','2026-09-06T00:04:01Z',NULL),
              ('usage','t1','turn1','info','task.progress','Late usage','{"taskId":"a"}','2026-09-06T00:04:02Z',NULL);
            """)
        refresh(80)
        expect(store.runningCount, 1, "one idle child does not finish another live child")
        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('cancel','t1','turn1','info','task.updated','Agent B cancelled','{"taskId":"b","status":"cancelled"}','2026-09-06T00:04:03Z',NULL);
            """)
        refresh(90)
        store.tick(at: time.addingTimeInterval(94))
        expect(store.runningCount, 0, "cancellation ends work and late usage does not revive idle agents")
        expect(events.count, 2, "multiple children produce one parent completion")

        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('survivor','t1','turn2','info','task.started','Surviving agent','{"taskId":"survivor"}','2026-09-06T00:04:10Z',NULL);
            INSERT INTO orchestration_events VALUES
              (90,'thread','t1','thread.session-set','{"session":{"status":"error"}}','2026-09-06T00:04:11Z');
            UPDATE projection_thread_sessions SET status='error';
            UPDATE projection_turns SET state='error';
            """)
        refresh(100)
        sql("""
            UPDATE projection_thread_sessions SET status='ready';
            INSERT INTO projection_turns (thread_id,turn_id,state,requested_at,started_at,completed_at,checkpoint_files_json)
              VALUES ('t1','turn3','completed','2026-09-06T00:04:12Z','2026-09-06T00:04:12Z','2026-09-06T00:04:13Z','[]');
            INSERT INTO projection_thread_activities VALUES
              ('survivor-progress','t1','turn2','info','task.progress','Still working','{"taskId":"survivor"}','2026-09-06T00:04:14Z',NULL);
            """)
        let eventsBeforeRetry = events.count
        refresh(110)
        store.tick(at: time.addingTimeInterval(120))
        expect(store.runningCount, 1, "surviving child keeps a successful retry active after a main-turn failure")
        expect(events.count, eventsBeforeRetry, "successful retry does not announce completion while the child survives")

        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('orphan','t1','turn2','info','task.started','Old agent','{"taskId":"orphan"}','2026-09-06T00:05:00Z',NULL);
            INSERT INTO orchestration_events VALUES
              (100,'thread','t1','thread.session-set','{"session":{"status":"stopped"}}','2026-09-06T00:05:01Z');
            """)
        let restartedReader = T3Reader()
        expect(try! restartedReader.snapshot(from: database, focusLimit: 6).runs[0].hasBackgroundWork,
               false, "a fresh reader ignores orphaned tasks from a stopped session")
        sql("""
            INSERT INTO projection_thread_activities VALUES
              ('new-agent','t1','turn2','info','task.started','New agent','{"taskId":"new"}','2026-09-06T00:05:02Z',NULL);
            """)
        expect(try! restartedReader.snapshot(from: database, focusLimit: 6).runs[0].hasBackgroundWork,
               true, "a fresh reader recovers live work after the session boundary")

    }
}

run("Session pauses and interruptions do not masquerade as completion") {
    MainActor.assumeIsolated {
        let store = T3Store()
        let time = Date()
        var events: [NotchEvent] = []
        store.onEvent = { events.append($0) }
        func snapshot(_ run: AgentRun) -> T3Reader.Snapshot { .init(runs: [run], turns: [:]) }
        store.apply(snapshot(makeRun(status: .running)), at: time)
        store.apply(snapshot(makeRun(status: .ready, turnState: "running")), at: time.addingTimeInterval(10))
        store.tick(at: time.addingTimeInterval(20))
        expect(store.runningCount, 1, "a running turn survives a ready session")
        expect(events.count, 0, "a ready session with a running turn does not finish")
        store.apply(snapshot(makeRun(status: .ready, questions: 1)), at: time.addingTimeInterval(30))
        expect(store.attentionCount, 1, "waiting for input remains visible as attention")
        expect(events.count, 0, "waiting for input does not announce completion")
        store.apply(snapshot(makeRun(status: .interrupted, turnState: "interrupted")), at: time.addingTimeInterval(40))
        store.tick(at: time.addingTimeInterval(50))
        expect(store.runningCount, 0, "interruptions clear the working row immediately")
        expect(events.count, 0, "interruptions stay quiet")
        store.apply(snapshot(makeRun(status: .running)), at: time.addingTimeInterval(60))
        store.apply(snapshot(makeRun(status: .error)), at: time.addingTimeInterval(70))
        expect(events.count, 1, "failures are announced immediately")
    }
}

run("Terminal events override retained attention in completion bookkeeping") {
    MainActor.assumeIsolated {
        let time = Date()
        for waiting in [makeRun(plan: true), makeRun(approvals: 1), makeRun(questions: 1)] {
            let store = T3Store()
            var events: [NotchEvent] = []
            store.onEvent = { if case .failed = $0 { events.append($0) } }
            store.apply(.init(runs: [makeRun(status: .running)], turns: [:]), at: time)
            var failed = waiting
            failed.status = .error
            store.apply(.init(runs: [failed], turns: [:]), at: time.addingTimeInterval(10))
            expect(events.count, 1, "failure is announced despite outstanding attention")
            store.tick(at: time.addingTimeInterval(20))
            expect(events.count, 1, "failure is announced only once")

            let interruptedStore = T3Store()
            var interruptionEvents: [NotchEvent] = []
            interruptedStore.onEvent = {
                switch $0 {
                case .completed, .failed: interruptionEvents.append($0)
                case .needsInput, .needsApproval: break
                }
            }
            interruptedStore.apply(.init(runs: [makeRun(status: .running)], turns: [:]), at: time)
            var interrupted = waiting
            interrupted.status = .interrupted
            interruptedStore.apply(.init(runs: [interrupted], turns: [:]), at: time.addingTimeInterval(10))
            interruptedStore.apply(.init(runs: [makeRun()], turns: [:]), at: time.addingTimeInterval(20))
            interruptedStore.tick(at: time.addingTimeInterval(30))
            expect(interruptionEvents.count, 0, "clearing stale attention after interruption does not announce success")
        }
    }
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
