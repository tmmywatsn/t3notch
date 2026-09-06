import Foundation

/// Folds T3 Code's persisted task lifecycle, including tasks outliving their turn.
/// Status-less usage/progress updates must never revive an idle or finished agent.
struct BackgroundTasks {
    private var live: Set<String> = []
    var hasWork: Bool { !live.isEmpty }

    mutating func record(kind: String, payload: [String: Any]) {
        guard let id = payload.string("taskId"), !id.isEmpty else { return }
        let type = payload.string("taskType")
        let status = payload.string("status")
        let monitors: Set<String> = ["monitor", "monitor_mcp", "local_bash", "shell"]
        let terminal: Set<String> = ["idle", "completed", "failed", "stopped", "cancelled", "interrupted"]
        if type == "plan" || type == "dream"
            || (payload.string("agentId") != nil && (type == nil || type.map(monitors.contains) == true))
            || kind == "task.completed" || status.map(terminal.contains) == true {
            live.remove(id)
            return
        }
        if kind == "task.started" || status != nil {
            live.insert(id)
        }
    }
}
