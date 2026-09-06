import Foundation

/// T3 Code's own session states, from `SessionStatus` in its wire schema.
enum SessionStatus: String {
    case idle
    case starting
    case running
    case ready
    case interrupted
    case stopped
    case error
    /// A state this build doesn't know about yet; treated as not working.
    case unknown

    /// `starting` counts as working — the agent is spinning up and the notch
    /// should say so rather than look idle for a second or two.
    var isBusy: Bool { self == .running || self == .starting }

    var isFaulted: Bool { self == .error }
}

enum ActivityTone: String {
    case info
    case tool
    case error
}

/// How a thread reads at a glance.
///
/// Uses T3 Code's attention/error precedence, with background work and a brief
/// handoff grace period keeping otherwise settled threads in the working view.
enum ThreadPhase {
    case waitingForApproval
    case waitingForInput
    case failed
    case starting
    case running
    case completed
    case stale

    var wantsYou: Bool { self == .waitingForApproval || self == .waitingForInput }
    var isWorking: Bool { self == .running || self == .starting }
}

struct ActivityLine: Identifiable, Equatable {
    let id: String
    let kind: String
    let tone: ActivityTone
    let summary: String
    /// A one-line "what it is doing" string, e.g. `Bash: git status`.
    let detail: String?
    /// Identifies the tool call, so started/updated/completed collapse to one row.
    let callID: String?
    let status: String?
    let createdAt: Date

    var isInFlight: Bool { status == "inProgress" || kind.hasSuffix(".started") }
    var failed: Bool { tone == .error || status == "failed" || status == "error" }
}

struct ContextWindow: Equatable {
    /// Where the notch starts warning, and where the warning turns urgent.
    /// One definition, so the collapsed ring and the expanded bar agree.
    static let warning = 0.8
    static let critical = 0.92

    let used: Int
    let max: Int

    var fraction: Double { max > 0 ? min(1, Double(used) / Double(max)) : 0 }
    var isWarning: Bool { fraction >= Self.warning }
    var isCritical: Bool { fraction >= Self.critical }
}

struct PendingQuestion: Identifiable, Equatable {
    let id: String
    let header: String
    let question: String
    let createdAt: Date
}

/// One T3 Code thread, flattened into everything the notch wants to show.
struct AgentRun: Identifiable, Equatable {
    let id: String
    var title: String
    var projectID: String
    var projectTitle: String
    var branch: String?
    var status: SessionStatus
    var provider: String?
    var model: String?
    var activeTurnID: String?
    var lastError: String?
    var turnStartedAt: Date?
    /// T3 Code's `latestTurn.state`; the phase rules need it alongside the session.
    var turnState: String?
    var pendingApprovals: Int
    var pendingQuestions: Int
    var hasActionablePlan: Bool
    var updatedAt: Date

    var hasBackgroundWork = false
    /// Briefly retain the working row while handoff events catch up.
    var isInHandoff = false

    // Filled in only for the threads the notch actually displays.
    var recentActivity: [ActivityLine] = []
    var context: ContextWindow?
    var questions: [PendingQuestion] = []
    var planStep: String?

    var phase: ThreadPhase {
        if pendingApprovals > 0 { return .waitingForApproval }
        if pendingQuestions > 0 { return .waitingForInput }
        if status.isFaulted || turnState == "error" { return .failed }
        if status == .starting { return .starting }
        if hasOngoingWork || isInHandoff { return .running }
        if turnState == "completed" { return .completed }
        return .stale
    }

    /// A proposed plan only counts as blocking once the agent has stopped and is
    /// waiting on it; while it is still working, the live view is more useful.
    var needsAttention: Bool {
        phase.wantsYou || (hasActionablePlan && !hasOngoingWork)
    }

    /// Independent of attention precedence: waiting for approval doesn't end a run.
    var hasOngoingWork: Bool {
        guard !isStoppedOrFailed else { return false }
        return status.isBusy || turnState == "running" || turnState == "pending" || hasBackgroundWork
    }

    /// Stop/failure signals end transition tracking even when attention flags
    /// linger. A completed main turn, in contrast, can still have live children.
    var isStoppedOrFailed: Bool {
        status.isFaulted || status == .stopped || status == .interrupted
            || turnState == "error" || turnState == "interrupted"
    }

    /// Stable ordering key: when this thread's current run began.
    ///
    /// Deliberately not `updatedAt` — that moves with every tool call, which made
    /// rows and dots reshuffle several times a second.
    var startedKey: Date { turnStartedAt ?? updatedAt }

    /// The one definition of "doing work you'd want to watch".
    ///
    /// Derived from `phase`, so a thread that is running *and* waiting on you
    /// counts as waiting, not as running, and is never reported twice.
    var isWorking: Bool { phase.isWorking }
}

/// A run that has stopped and is waiting for you to notice it.
struct FinishedRun: Identifiable, Equatable {
    let id: String
    var threadID: String { id }
    var title: String
    var projectTitle: String
    var provider: String?
    var finishedAt: Date
    var duration: TimeInterval?
    var additions: Int
    var deletions: Int
    var fileCount: Int
    var failed: Bool
    var errorText: String?
}

/// Something the notch should announce, in the order it happened.
enum NotchEvent: Equatable {
    case completed(FinishedRun)
    case failed(FinishedRun)
    case needsInput(title: String, question: String)
    case needsApproval(title: String)
}

extension String {
    /// Collapses whitespace and clips, so a shell command fits on one notch line.
    func singleLine(limit: Int = 120) -> String {
        let flattened = split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

extension TimeInterval {
    /// `2m 14s`, `1h 03m`, `940ms`.
    var runDuration: String {
        if self < 1 { return "\(Int(self * 1000))ms" }
        let total = Int(self.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return "\(minutes)m \(seconds)s" }
        return "\(seconds)s"
    }
}

extension Date {
    /// `just now`, `4m ago`, `2h ago`.
    func ago(from reference: Date) -> String {
        let seconds = Int(reference.timeIntervalSince(self))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }
}

extension Dictionary where Key == String, Value == Any {
    func string(_ key: String) -> String? { self[key] as? String }
    func int(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? Double { return Int(value) }
        if let value = self[key] as? NSNumber { return value.intValue }
        return nil
    }
    func dict(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]]? { self[key] as? [[String: Any]] }
}
