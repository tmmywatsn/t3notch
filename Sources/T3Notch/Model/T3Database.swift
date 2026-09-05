import Foundation

/// Where T3 Code keeps its state on disk.
enum T3Paths {
    /// `T3NOTCH_USERDATA` points the app at a fixture directory instead of the
    /// real one, which is how the run-completion path gets exercised without
    /// waiting on a live agent.
    static let userData: URL = {
        if let override = ProcessInfo.processInfo.environment["T3NOTCH_USERDATA"] {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".t3/userdata")
    }()
    static var database: URL { userData.appendingPathComponent("state.sqlite") }
    static var walJournal: URL { userData.appendingPathComponent("state.sqlite-wal") }
}

struct TurnRecord {
    let threadID: String
    let turnID: String?
    let state: String
    let requestedAt: Date?
    let startedAt: Date?
    let completedAt: Date?
    let additions: Int
    let deletions: Int
    let fileCount: Int
}

struct PlanStep {
    let step: String
    let status: String
}

/// Read-only queries against T3 Code's projection tables.
///
/// These tables are T3 Code's private storage rather than a published API, so
/// every read is defensive: a missing table or renamed column degrades the
/// notch to "not connected" instead of crashing.
final class T3Database {
    private let connection: SQLiteConnection

    init() throws {
        connection = try SQLiteConnection(path: T3Paths.database.path)
    }

    func close() { connection.close() }

    // MARK: - Threads

    func threads(limit: Int = 60) throws -> [AgentRun] {
        var runs: [AgentRun] = []
        try connection.query(
            """
            SELECT t.thread_id, t.title, t.project_id, COALESCE(p.title, ''), t.branch,
                   COALESCE(s.status, 'unknown'), s.provider_name, s.active_turn_id, s.last_error,
                   t.model_selection_json, t.pending_approval_count, t.pending_user_input_count,
                   t.has_actionable_proposed_plan, t.updated_at
            FROM projection_threads t
            LEFT JOIN projection_thread_sessions s ON s.thread_id = t.thread_id
            LEFT JOIN projection_projects p ON p.project_id = t.project_id
            WHERE t.deleted_at IS NULL AND t.archived_at IS NULL
            ORDER BY t.updated_at DESC
            LIMIT \(limit)
            """
        ) { row in
            let branch = row.string(4)
            runs.append(
                AgentRun(
                    id: row.text(0),
                    title: row.text(1).isEmpty ? "Untitled thread" : row.text(1),
                    projectID: row.text(2),
                    projectTitle: row.text(3),
                    branch: (branch?.isEmpty ?? true) ? nil : branch,
                    status: SessionStatus(rawValue: row.text(5)) ?? .unknown,
                    provider: row.string(6),
                    model: row.json(9).string("model"),
                    activeTurnID: row.string(7),
                    lastError: row.string(8),
                    turnStartedAt: nil,
                    turnState: nil,
                    pendingApprovals: Int(row.int(10)),
                    pendingQuestions: Int(row.int(11)),
                    hasActionablePlan: row.int(12) != 0,
                    updatedAt: row.date(13) ?? .distantPast
                )
            )
        }
        return runs
    }

    /// The most recent turn for every thread, keyed by thread id.
    func latestTurns() throws -> [String: TurnRecord] {
        var turns: [String: TurnRecord] = [:]
        try connection.query(
            """
            SELECT thread_id, turn_id, state, requested_at, started_at, completed_at, checkpoint_files_json
            FROM projection_turns
            WHERE row_id IN (SELECT MAX(row_id) FROM projection_turns GROUP BY thread_id)
            """
        ) { row in
            let files = Self.diffStat(row.string(6))
            let record = TurnRecord(
                threadID: row.text(0),
                turnID: row.string(1),
                state: row.text(2),
                requestedAt: row.date(3),
                startedAt: row.date(4),
                completedAt: row.date(5),
                additions: files.additions,
                deletions: files.deletions,
                fileCount: files.count
            )
            turns[record.threadID] = record
        }
        return turns
    }

    // MARK: - Activity

    func activity(threadID: String, limit: Int = 40) throws -> [ActivityLine] {
        var lines: [ActivityLine] = []
        try connection.query(
            """
            SELECT activity_id, kind, tone, summary, payload_json, created_at
            FROM projection_thread_activities
            WHERE thread_id = ?
            ORDER BY sequence DESC, created_at DESC
            LIMIT \(limit)
            """,
            bind: [.text(threadID)]
        ) { row in
            let payload = row.json(4)
            let kind = row.text(1)
            lines.append(
                ActivityLine(
                    id: row.text(0),
                    kind: kind,
                    tone: ActivityTone(rawValue: row.text(2)) ?? .info,
                    summary: row.text(3),
                    detail: Self.detail(kind: kind, payload: payload),
                    callID: payload.string("toolCallId") ?? payload.string("taskId"),
                    status: payload.string("status"),
                    createdAt: row.date(5) ?? .distantPast
                )
            )
        }
        return lines
    }

    /// Latest context-window reading for a thread.
    func contextWindow(threadID: String) throws -> ContextWindow? {
        var window: ContextWindow?
        try connection.query(
            """
            SELECT payload_json FROM projection_thread_activities
            WHERE thread_id = ? AND kind = 'context-window.updated'
            ORDER BY sequence DESC, created_at DESC LIMIT 1
            """,
            bind: [.text(threadID)]
        ) { row in
            let payload = row.json(0)
            guard let max = payload.int("maxTokens"), max > 0 else { return }
            window = ContextWindow(used: payload.int("usedTokens") ?? 0, max: max)
        }
        return window
    }

    /// The agent's current plan, newest first.
    func plan(threadID: String) throws -> [PlanStep] {
        var steps: [PlanStep] = []
        try connection.query(
            """
            SELECT payload_json FROM projection_thread_activities
            WHERE thread_id = ? AND kind = 'turn.plan.updated'
            ORDER BY sequence DESC, created_at DESC LIMIT 1
            """,
            bind: [.text(threadID)]
        ) { row in
            for entry in row.json(0).array("plan") ?? [] {
                guard let step = entry.string("step") else { continue }
                steps.append(PlanStep(step: step, status: entry.string("status") ?? "pending"))
            }
        }
        return steps
    }

    /// Questions the agent asked that nobody has answered yet.
    func openQuestions(threadID: String) throws -> [PendingQuestion] {
        var requested: [String: PendingQuestion] = [:]
        var resolved: Set<String> = []
        try connection.query(
            """
            SELECT kind, payload_json, created_at FROM projection_thread_activities
            WHERE thread_id = ? AND kind IN ('user-input.requested', 'user-input.resolved')
            ORDER BY sequence DESC, created_at DESC LIMIT 20
            """,
            bind: [.text(threadID)]
        ) { row in
            let payload = row.json(1)
            guard let requestID = payload.string("requestId") else { return }
            if row.text(0) == "user-input.resolved" {
                resolved.insert(requestID)
                return
            }
            let first = payload.array("questions")?.first
            requested[requestID] = PendingQuestion(
                id: requestID,
                header: first?.string("header") ?? "Question",
                question: (first?.string("question") ?? "").singleLine(limit: 240),
                createdAt: row.date(2) ?? .distantPast
            )
        }
        return requested
            .filter { !resolved.contains($0.key) }
            .values
            .sorted { $0.createdAt > $1.createdAt }
    }

    func pendingApprovalCount() throws -> [String: Int] {
        var counts: [String: Int] = [:]
        try connection.query(
            """
            SELECT thread_id, COUNT(*) FROM projection_pending_approvals
            WHERE status = 'pending' GROUP BY thread_id
            """
        ) { row in
            counts[row.text(0)] = Int(row.int(1))
        }
        return counts
    }

    // MARK: - Payload helpers

    private static func diffStat(_ json: String?) -> (additions: Int, deletions: Int, count: Int) {
        guard let json, let data = json.data(using: .utf8),
              let files = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return (0, 0, 0) }
        let additions = files.reduce(0) { $0 + ($1.int("additions") ?? 0) }
        let deletions = files.reduce(0) { $0 + ($1.int("deletions") ?? 0) }
        return (additions, deletions, files.count)
    }

    /// The one-line "what is it doing" string for an activity.
    private static func detail(kind: String, payload: [String: Any]) -> String? {
        if kind.hasPrefix("tool.") {
            if let detail = payload.string("detail"), !detail.isEmpty {
                return detail.singleLine()
            }
            // File edits carry no detail string, only the changed paths.
            if let changes = payload.dict("data")?.dict("item")?.array("changes"),
               let path = changes.first?.string("path") {
                let name = (path as NSString).lastPathComponent
                return changes.count > 1 ? "Edit: \(name) +\(changes.count - 1) more" : "Edit: \(name)"
            }
            return payload.dict("data")?.string("toolName")
        }
        if kind.hasPrefix("task.") {
            return payload.string("title")?.singleLine()
        }
        if kind == "runtime.error" || kind == "runtime.warning" {
            return payload.string("message")?.singleLine()
        }
        return nil
    }
}
