import Foundation

/// Owns the SQLite connection and does every read on a serial background queue,
/// so a growing activity log never stutters the panel's animations.
final class T3Reader {
    struct Snapshot {
        let runs: [AgentRun]
        let turns: [String: TurnRecord]
    }

    enum Outcome {
        case success(Snapshot)
        case failure(String)
    }

    private let queue = DispatchQueue(label: "com.tmmywatsn.t3notch.database", qos: .utility)
    private var database: T3Database?
    private var reconnectDeadline = Date.distantPast

    func read(focusLimit: Int, completion: @escaping (Outcome) -> Void) {
        queue.async { [self] in
            guard let database = connect() else {
                completion(.failure(statusMessage))
                return
            }
            do {
                completion(.success(try snapshot(from: database, focusLimit: focusLimit)))
            } catch {
                // Usually T3 Code quitting and taking its WAL with it, but it
                // could be a renamed column, so keep the detail for debugging.
                Debug.log("read failed: \(error.localizedDescription)")
                self.database = nil
                reconnectDeadline = Date().addingTimeInterval(3)
                completion(.failure("Waiting for T3 Code"))
            }
        }
    }

    func close() {
        queue.async { [self] in
            database?.close()
            database = nil
        }
    }

    // MARK: - Connection

    private var statusMessage: String {
        FileManager.default.fileExists(atPath: T3Paths.database.path)
            ? "Waiting for T3 Code"
            : "T3 Code isn't installed on this Mac"
    }

    private func connect() -> T3Database? {
        if let database { return database }
        // A read-only handle needs the -shm file, which only exists while T3 Code
        // is running. Back off between attempts rather than spinning.
        guard Date() >= reconnectDeadline else { return nil }
        do {
            let opened = try T3Database()
            database = opened
            return opened
        } catch {
            Debug.log("connect failed: \(error.localizedDescription)")
            reconnectDeadline = Date().addingTimeInterval(3)
            return nil
        }
    }

    // MARK: - Reads

    func snapshot(from database: T3Database, focusLimit: Int) throws -> Snapshot {
        let threads = try database.threads()
        let turns = try database.latestTurns()
        let approvals = try database.pendingApprovalCount()

        var runs = try threads.map { thread -> AgentRun in
            var run = thread
            if let turn = turns[run.id] {
                run.turnStartedAt = turn.startedAt ?? turn.requestedAt
                run.turnState = turn.state
            }
            if let count = approvals[run.id] { run.pendingApprovals = count }
            if run.status != .stopped && run.status != .interrupted && !run.status.isFaulted {
                run.hasBackgroundWork = try database.hasBackgroundWork(threadID: run.id)
            }
            return run
        }
        runs = Self.focusOrder(runs)

        // Only the handful of threads the notch can actually show are worth the
        // extra per-thread queries.
        for index in runs.indices.prefix(focusLimit) {
            try enrich(&runs[index], using: database)
        }
        return Snapshot(runs: runs, turns: turns)
    }

    private func enrich(_ run: inout AgentRun, using database: T3Database) throws {
        run.recentActivity = Self.feed(from: try database.activity(threadID: run.id, limit: 40))
        run.context = try database.contextWindow(threadID: run.id)
        run.questions = try database.openQuestions(threadID: run.id)
        run.pendingQuestions = max(run.pendingQuestions, run.questions.count)

        let plan = try database.plan(threadID: run.id)
        let done = plan.filter { $0.status == "completed" }.count
        if let next = plan.first(where: { $0.status != "completed" }) {
            run.planStep = "\(done + 1)/\(plan.count) \(next.step)"
        } else if !plan.isEmpty {
            run.planStep = "\(plan.count)/\(plan.count) plan complete"
        }
    }

    /// Keeps the human-meaningful activity and drops the bookkeeping noise.
    private static func feed(from activity: [ActivityLine]) -> [ActivityLine] {
        let noise: Set<String> = ["context-window.updated", "task.progress", "checkpoint.captured"]
        var seenCalls: Set<String> = []
        return activity.filter { line in
            if noise.contains(line.kind) { return false }
            // started/updated/completed all describe one call, and the list is
            // newest-first, so the first one we meet is the current state.
            guard let call = line.callID else { return true }
            return seenCalls.insert(call).inserted
        }
    }

    /// Anything waiting on you, then anything running, then the rest — and
    /// newest first within each group, keyed off when the run started so the
    /// order holds still while an agent works.
    private static func focusOrder(_ runs: [AgentRun]) -> [AgentRun] {
        runs.sorted { left, right in
            func rank(_ run: AgentRun) -> Int {
                if run.needsAttention { return 0 }
                if run.isWorking { return 1 }
                return 2
            }
            let (a, b) = (rank(left), rank(right))
            if a != b { return a < b }
            if left.startedKey != right.startedKey { return left.startedKey > right.startedKey }
            // Same instant: fall back to the id so the order is at least fixed.
            return left.id < right.id
        }
    }
}
