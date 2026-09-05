import SwiftUI

private enum Layout {
    static let maxRunCards = 3
    static let maxFinished = 3
    static let maxRecent = 3
    static let maxAttention = 2
}

// MARK: - Expanded

struct ExpandedContent: View {
    @ObservedObject var store: T3Store
    @ObservedObject var controller: NotchController
    @ObservedObject var settings: Settings
    let metrics: NotchMetrics
    let width: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if controller.showingSettings {
                SettingsList(settings: settings)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    attentionSection
                    runningSection
                    finishedSection
                    idleSection
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                // Scoped to the list so it never fights the settings controls.
                .contentShape(Rectangle())
                .onTapGesture { T3Code.activate() }
            }
            footer
        }
    }

    private var runningRuns: [AgentRun] { store.runs.filter(\.isWorking) }

    /// Threads that are neither running nor waiting: only worth the space when
    /// there is nothing more urgent to show.
    private var idleRuns: [AgentRun] {
        let shown = Set(store.finished.map(\.id))
        return store.runs.filter { !$0.isWorking && !$0.needsAttention && !shown.contains($0.id) }
    }

    private var attentionItems: [AgentRun] { store.runs.filter(\.needsAttention) }

    private var headerRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.connected ? Color.green.opacity(0.8) : Color.orange.opacity(0.8))
                    .frame(width: 5, height: 5)
                Text("T3 Code")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Spacer(minLength: 0)
            }
            .padding(.leading, 14)
            .frame(width: sideWidth, alignment: .leading)

            Color.clear.frame(width: metrics.width)

            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Text(summary)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
            .padding(.trailing, 14)
            .frame(width: sideWidth, alignment: .trailing)
        }
        .frame(height: metrics.height)
    }

    /// The menu bar strip on each side of the cutout.
    private var sideWidth: CGFloat { (width - metrics.width) / 2 }

    private var summary: String {
        var parts: [String] = []
        if store.runningCount > 0 { parts.append("\(store.runningCount) running") }
        if store.attentionCount > 0 { parts.append("\(store.attentionCount) waiting") }
        if parts.isEmpty { parts.append(store.connected ? "idle" : "offline") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var attentionSection: some View {
        let items = attentionItems.prefix(Layout.maxAttention)
        if !items.isEmpty {
            VStack(spacing: 6) {
                ForEach(Array(items)) { run in AttentionCard(run: run) }
            }
        }
    }

    @ViewBuilder private var runningSection: some View {
        // `isWorking` already excludes anything waiting on you.
        let running = runningRuns
        if !running.isEmpty {
            SectionLabel(text: "Running")
            VStack(spacing: 6) {
                // One agent has room for a short history; several do not.
                let lines = running.count == 1 ? 3 : 1
                ForEach(Array(running.prefix(Layout.maxRunCards))) { run in
                    RunCard(run: run, now: store.now, activityLines: lines)
                }
            }
            if running.count > Layout.maxRunCards {
                MoreLabel(count: running.count - Layout.maxRunCards)
            }
        }
    }

    @ViewBuilder private var finishedSection: some View {
        if !store.finished.isEmpty {
            SectionLabel(text: "Just finished")
            VStack(spacing: 4) {
                ForEach(Array(store.finished.prefix(Layout.maxFinished))) { run in
                    FinishedRow(run: run)
                }
            }
        }
    }

    @ViewBuilder private var idleSection: some View {
        if attentionItems.isEmpty, runningRuns.isEmpty {
            let recent = idleRuns.prefix(Layout.maxRecent)
            if recent.isEmpty {
                EmptyStateView(store: store)
            } else {
                SectionLabel(text: "Recent")
                VStack(spacing: 4) {
                    ForEach(Array(recent)) { run in RecentRow(run: run, now: store.now) }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(footerHint)
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.35))
            Spacer(minLength: 0)
            Button {
                controller.toggleSettings()
            } label: {
                Image(systemName: controller.showingSettings ? "chevron.backward" : "gearshape.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.45))
                    // Trailing-aligned inside a larger hit area, so the glyph
                    // lines up with the column of switches above it while
                    // staying comfortable to click.
                    .frame(width: 22, height: 20, alignment: .trailing)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(controller.showingSettings ? "Back" : "Settings")
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }

    private var footerHint: String {
        if controller.showingSettings { return "Preferences are stored on this Mac only" }
        return store.statusMessage ?? "Click to open T3 Code"
    }
}

private struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.white.opacity(0.35))
            .padding(.top, 2)
    }
}

private struct MoreLabel: View {
    let count: Int
    var body: some View {
        Text("+\(count) more in T3 Code")
            .font(.system(size: 9.5))
            .foregroundStyle(.white.opacity(0.35))
    }
}

private struct EmptyStateView: View {
    @ObservedObject var store: T3Store

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(store.connected ? "No agents running" : "Waiting for T3 Code")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
            Text(store.connected
                 ? "Start a run in T3 Code and it shows up here."
                 : "Open T3 Code to start syncing.")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }
}

// MARK: - Cards

private struct RunCard: View {
    let run: AgentRun
    let now: Date
    let activityLines: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle()
                    .fill(ProviderStyle.accent(for: run.provider))
                    .frame(width: 6, height: 6)
                Text(run.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer(minLength: 6)
                if let elapsed = run.turnStartedAt.map({ now.timeIntervalSince($0) }), elapsed > 0 {
                    Text(elapsed.runDuration)
                        .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.6))
                }
            }

            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)

            ForEach(Array(run.recentActivity.prefix(activityLines).enumerated()), id: \.element.id) { index, activity in
                HStack(spacing: 5) {
                    Image(systemName: activity.failed
                          ? "xmark.circle.fill"
                          : (activity.isInFlight ? "circle.dotted" : "checkmark.circle.fill"))
                        .font(.system(size: 8.5))
                        .foregroundStyle(activity.failed
                                         ? Color.red.opacity(0.9)
                                         : (activity.isInFlight
                                            ? ProviderStyle.accent(for: run.provider)
                                            : Color.white.opacity(0.35)))
                    Text(activity.detail ?? activity.summary)
                        .font(.system(size: 10).monospaced())
                        .foregroundStyle(.white.opacity(opacity(for: activity, at: index)))
                        .lineLimit(1)
                }
            }

            if let step = run.planStep {
                Text(step)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.42))
                    .lineLimit(1)
            }

            if let context = run.context {
                ContextBar(context: context, accent: ProviderStyle.accent(for: run.provider))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// Older lines fade, so the live one reads first.
    private func opacity(for activity: ActivityLine, at index: Int) -> Double {
        if activity.isInFlight { return 0.8 }
        return index == 0 ? 0.55 : 0.35
    }

    private var subtitle: String {
        var parts: [String] = []
        if !run.projectTitle.isEmpty { parts.append(run.projectTitle) }
        if let branch = run.branch { parts.append(branch) }
        parts.append(ProviderStyle.name(for: run.provider))
        if let model = run.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }
}

private struct ContextBar: View {
    let context: ContextWindow
    let accent: Color

    var body: some View {
        HStack(spacing: 6) {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule()
                        .fill(context.isWarning ? Color.orange : accent.opacity(0.85))
                        .frame(width: max(2, proxy.size.width * context.fraction))
                }
            }
            .frame(height: 3)
            Text("\(Int(context.fraction * 100))% ctx")
                .font(.system(size: 9).monospacedDigit())
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.top, 1)
    }
}

private struct AttentionCard: View {
    let run: AgentRun

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.orange.opacity(0.14))
        )
    }

    private var symbol: String {
        if run.pendingApprovals > 0 { return "hand.raised.fill" }
        if run.pendingQuestions > 0 { return "questionmark.circle.fill" }
        return "list.bullet.rectangle"
    }

    private var headline: String {
        if run.pendingApprovals > 0 { return "\(run.title) needs approval" }
        if run.pendingQuestions > 0 { return "\(run.title) asked you something" }
        return "\(run.title) has a plan for you"
    }

    private var detail: String {
        if let question = run.questions.first {
            return question.question.isEmpty ? question.header : question.question
        }
        if run.pendingApprovals > 0 {
            return "\(run.pendingApprovals) pending approval\(run.pendingApprovals == 1 ? "" : "s")"
        }
        return run.planStep ?? run.projectTitle
    }
}

/// A thread that is sitting idle, so you can see what you were last working on.
private struct RecentRow: View {
    let run: AgentRun
    let now: Date

    var body: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(ProviderStyle.accent(for: run.provider).opacity(0.6))
                .frame(width: 5, height: 5)
            Text(run.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(run.updatedAt.ago(from: now))
                .font(.system(size: 9.5))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

private struct FinishedRow: View {
    let run: FinishedRun

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: run.failed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(run.failed ? Color.red.opacity(0.9) : Color.green.opacity(0.85))
            Text(run.title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(trailing)
                .font(.system(size: 9.5).monospacedDigit())
                .foregroundStyle(.white.opacity(0.45))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }

    private var trailing: String {
        var parts: [String] = []
        if let duration = run.duration { parts.append(duration.runDuration) }
        if run.fileCount > 0 { parts.append("+\(run.additions) −\(run.deletions)") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Settings

private struct SettingsList: View {
    @ObservedObject var settings: Settings

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingRow(
                title: "Banner in the notch",
                detail: "Drop down a summary when a run finishes",
                isOn: $settings.showBanner
            )
            SettingRow(
                title: "Play a sound",
                detail: "A chime on finish, a thud on failure",
                isOn: $settings.soundEnabled
            )
            SettingRow(
                title: "Announce short runs",
                detail: "Include turns under three seconds",
                isOn: $settings.announceShortRuns
            )
            // Both need a Developer ID; macOS refuses them to ad-hoc builds.
            if CodeSignature.isIdentified {
                SettingRow(
                    title: "Notification Centre",
                    detail: "Post a system banner as well",
                    isOn: $settings.systemNotifications
                )
                LoginItemRow()
            }
        }
    }
}

/// A standalone `Toggle` packs its label against its switch, so every switch
/// would land at a different x. The label and the control are laid out here
/// instead, which keeps the switches in one column.
private struct SettingRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.white.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.green)
        }
        .padding(.vertical, 4)
    }
}

/// Login items are registered with the system, not with our own preferences,
/// so the switch reflects whatever macOS actually accepted.
private struct LoginItemRow: View {
    @State private var enabled = LoginItem.isEnabled

    var body: some View {
        SettingRow(
            title: "Start at login",
            detail: "Open T3 Notch when you log in",
            isOn: Binding(
                get: { enabled },
                set: { LoginItem.set($0); enabled = LoginItem.isEnabled }
            )
        )
    }
}
