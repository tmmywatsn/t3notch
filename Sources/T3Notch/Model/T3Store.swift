import Combine
import Foundation

/// Watches T3 Code's local state and publishes what the notch should show.
///
/// T3 Code's HTTP API needs a paired credential, so instead of polling it we tail
/// the same on-disk state the app itself writes: a stat() on the SQLite WAL tells
/// us when something changed, and only then do we re-read the projections.
@MainActor
final class T3Store: ObservableObject {
    @Published private(set) var runs: [AgentRun] = []
    @Published private(set) var finished: [FinishedRun] = []
    /// True until you actually look at the notch, so the collapsed bar can stop
    /// nagging without throwing the list away while you are reading it.
    @Published private(set) var hasUnseenFinished = false
    @Published private(set) var connected = false
    @Published private(set) var statusMessage: String?
    /// Ticks once a second so elapsed timers stay live without re-querying.
    @Published private(set) var now = Date()

    var onEvent: ((NotchEvent) -> Void)?

    /// Runs shorter than this are housekeeping turns (title generation and the
    /// like) and are not worth announcing, unless you ask for them.
    private var minimumAnnouncedRun: TimeInterval { Settings.shared.announceShortRuns ? 0 : 3 }
    private let finishedRetention: TimeInterval = 30 * 60
    private let focusLimit = 6

    private var previouslyActive: Set<String> = []
    private var runningSince: [String: Date] = [:]
    private var runsWithBackgroundWork: Set<String> = []
    private var settlingSince: [String: Date] = [:]
    private let handoffGrace: TimeInterval = 3
    private var latestSnapshot: T3Reader.Snapshot?
    /// Keyed by thread so both can be pruned when a thread goes away.
    private var announcedQuestions: [String: Set<String>] = [:]
    private var announcedApprovals: [String: String] = [:]
    private var seeded = false

    private var watchToken: WatchToken = .init(walSize: -1, walModified: -1, databaseSize: -1)
    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var refreshInFlight = false

    private let reader = T3Reader()

    // MARK: - Lifecycle

    func start() {
        pollTimer = schedule(every: 0.25) { [weak self] in self?.pollForChanges() }
        tickTimer = schedule(every: 1) { [weak self] in self?.tick() }
        pollForChanges(force: true)
    }

    /// Settle even when the database stops changing after the final event.
    func tick(at time: Date = Date()) {
        now = time
        expireFinished()
        if !refreshInFlight, !settlingSince.isEmpty, let snapshot = latestSnapshot {
            apply(snapshot, at: time)
        }
    }

    func stop() {
        pollTimer?.invalidate()
        tickTimer?.invalidate()
        pollTimer = nil
        tickTimer = nil
        reader.close()
    }

    /// Timers run in `.common` modes so the notch keeps updating while a menu
    /// or a window resize is holding the run loop in tracking mode.
    private func schedule(every interval: TimeInterval, _ body: @escaping () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            Task { @MainActor in body() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    // MARK: - Finished runs

    /// Called when the panel opens: the badge stops nagging, the list stays.
    func markFinishedSeen() {
        hasUnseenFinished = false
    }

    /// Called when the panel closes: you've had your chance to read them.
    func clearSeenFinished() {
        guard !hasUnseenFinished else { return }
        finished.removeAll()
    }

    // MARK: - Change detection

    private struct WatchToken: Equatable {
        var walSize: Int64
        var walModified: TimeInterval
        var databaseSize: Int64
    }

    private func pollForChanges(force: Bool = false) {
        guard force || hasChangedOnDisk() else { return }
        refresh()
    }

    /// Cheap stat() on the WAL, so we only touch SQLite when T3 Code committed.
    private func hasChangedOnDisk() -> Bool {
        let manager = FileManager.default
        let wal = (try? manager.attributesOfItem(atPath: T3Paths.walJournal.path)) ?? [:]
        let main = (try? manager.attributesOfItem(atPath: T3Paths.database.path)) ?? [:]
        let token = WatchToken(
            walSize: (wal[.size] as? NSNumber)?.int64Value ?? 0,
            walModified: (wal[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0,
            databaseSize: (main[.size] as? NSNumber)?.int64Value ?? 0
        )
        guard token != watchToken else { return false }
        watchToken = token
        return true
    }

    // MARK: - Refresh

    private func refresh() {
        // SQLite work happens off the main thread; a run at four hertz is enough
        // to feel live, and dropping overlapping requests keeps it from piling up.
        guard !refreshInFlight else { return }
        refreshInFlight = true
        let focusLimit = self.focusLimit
        reader.read(focusLimit: focusLimit) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.refreshInFlight = false
                switch result {
                case let .success(snapshot):
                    self.apply(snapshot)
                case let .failure(message):
                    self.latestSnapshot = nil
                    self.settlingSince.removeAll()
                    self.connected = false
                    self.statusMessage = message
                    self.runs = []
                }
            }
        }
    }

    func apply(_ snapshot: T3Reader.Snapshot, at time: Date = Date()) {
        latestSnapshot = snapshot
        connected = true
        statusMessage = nil

        // The first pass only records the current state: everything already
        // running or waiting when the notch launches is not news.
        let firstPass = !seeded
        seeded = true

        // Ordered, not a dictionary: two runs finishing in the same refresh
        // must announce in a fixed order, not whatever the hash gives.
        let visibleRuns = bridgeHandoffs(in: snapshot.runs, at: time)
        detectTransitions(runs: visibleRuns, turns: snapshot.turns, at: time)
        detectAttention(runs: snapshot.runs, announcing: !firstPass)
        forget(threadsMissingFrom: snapshot.runs)

        runs = visibleRuns.filter { Self.isWorthShowing($0) }
    }

    private func bridgeHandoffs(in runs: [AgentRun], at time: Date) -> [AgentRun] {
        runs.map { run in
            var run = run
            let failed = run.phase == .failed || run.lastError?.isEmpty == false
            if run.hasOngoingWork || run.needsAttention || failed
                || run.isStoppedOrFailed {
                settlingSince[run.id] = nil
            } else if previouslyActive.contains(run.id) {
                let since = settlingSince[run.id] ?? time
                settlingSince[run.id] = since
                run.isInHandoff = time.timeIntervalSince(since) < handoffGrace
            }
            return run
        }
    }

    private static func isWorthShowing(_ run: AgentRun) -> Bool {
        run.isWorking || run.needsAttention
            || run.updatedAt > Date().addingTimeInterval(-30 * 60)
    }

    /// Threads get deleted and archived; without this the bookkeeping only ever
    /// grows for the lifetime of the process.
    private func forget(threadsMissingFrom runs: [AgentRun]) {
        let live = Set(runs.map(\.id))
        previouslyActive.formIntersection(live)
        runningSince = runningSince.filter { live.contains($0.key) }
        runsWithBackgroundWork.formIntersection(live)
        settlingSince = settlingSince.filter { live.contains($0.key) }
        announcedQuestions = announcedQuestions.filter { live.contains($0.key) }
        announcedApprovals = announcedApprovals.filter { live.contains($0.key) }
    }

    // MARK: - Event detection

    private func detectTransitions(runs: [AgentRun], turns: [String: TurnRecord], at time: Date) {
        for run in runs {
            let id = run.id
            if !run.isStoppedOrFailed && (run.hasOngoingWork || run.isInHandoff || run.needsAttention) {
                if run.hasBackgroundWork { runsWithBackgroundWork.insert(id) }
                if previouslyActive.insert(id).inserted {
                    runningSince[id] = run.turnStartedAt ?? time
                }
                continue
            }

            guard previouslyActive.remove(id) != nil else { continue }
            let settledAt = settlingSince.removeValue(forKey: id) ?? time
            let startedAt = runningSince.removeValue(forKey: id)
            let hadBackgroundWork = runsWithBackgroundWork.remove(id) != nil

            // You pressed stop, so you already know. Nothing to announce.
            if run.status == .interrupted || run.turnState == "interrupted" { continue }

            let turn = turns[id]
            // Preserve provider timing for ordinary short turns, even if a poll
            // was delayed. Background work can continue past that timestamp.
            let singleTurn = !hadBackgroundWork && startedAt == (turn?.startedAt ?? turn?.requestedAt)
            let endedAt = singleTurn ? (turn?.completedAt ?? settledAt) : settledAt
            let duration = startedAt.map { max(0, endedAt.timeIntervalSince($0)) }

            if let duration, duration < minimumAnnouncedRun { continue }

            let failed = turn?.state == "error" || run.status.isFaulted
                || (run.lastError?.isEmpty == false)
            let record = FinishedRun(
                id: id,
                title: run.title,
                projectTitle: run.projectTitle,
                provider: run.provider,
                finishedAt: endedAt,
                duration: duration,
                additions: turn?.additions ?? 0,
                deletions: turn?.deletions ?? 0,
                fileCount: turn?.fileCount ?? 0,
                failed: failed,
                errorText: run.lastError
            )
            finished.removeAll { $0.id == id }
            finished.insert(record, at: 0)
            hasUnseenFinished = true
            onEvent?(failed ? .failed(record) : .completed(record))
        }
    }

    private func detectAttention(runs: [AgentRun], announcing: Bool) {
        for run in runs {
            for question in run.questions where announcedQuestions[run.id]?.contains(question.id) != true {
                announcedQuestions[run.id, default: []].insert(question.id)
                guard announcing else { continue }
                onEvent?(.needsInput(title: run.title, question: question.question))
            }
            guard run.pendingApprovals > 0 else {
                announcedApprovals[run.id] = nil
                continue
            }
            let turn = run.activeTurnID ?? "-"
            if announcedApprovals[run.id] != turn {
                announcedApprovals[run.id] = turn
                if announcing { onEvent?(.needsApproval(title: run.title)) }
            }
        }
    }

    private func expireFinished() {
        let cutoff = Date().addingTimeInterval(-finishedRetention)
        finished.removeAll { $0.finishedAt < cutoff }
        if finished.isEmpty { hasUnseenFinished = false }
    }
}

extension T3Store {
    var runningCount: Int { runs.filter(\.isWorking).count }
    var attentionCount: Int { runs.filter(\.needsAttention).count }
    var hasAnythingToShow: Bool { runningCount > 0 || attentionCount > 0 || hasUnseenFinished }

    /// The fullest context window among working threads, once it is high enough
    /// to be worth warning about.
    var contextPressure: Double? {
        let worst = runs
            .filter(\.isWorking)
            .compactMap { $0.context }
            .max { $0.fraction < $1.fraction }
        guard let worst, worst.isWarning else { return nil }
        return worst.fraction
    }
}
