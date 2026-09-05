import SwiftUI

// MARK: - Root

struct NotchRootView: View {
    @ObservedObject var store: T3Store
    @ObservedObject var controller: NotchController

    var body: some View {
        VStack(spacing: 0) {
            card
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        content
            .frame(width: controller.cardSize(for: controller.mode).width, alignment: .top)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                NotchShape()
                    .fill(Color.black.opacity(backgroundOpacity))
                    .overlay(
                        NotchShape()
                            .stroke(Color.white.opacity(controller.mode == .collapsed ? 0 : 0.09),
                                    lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(controller.mode == .collapsed ? 0 : 0.45),
                            radius: 12, y: 4)
            )
            .contentShape(Rectangle())
            .background(
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { controller.contentHeightChanged(proxy.size.height) }
                        .onChange(of: proxy.size.height) { _, height in
                            controller.contentHeightChanged(height)
                        }
                }
            )
            .animation(.easeOut(duration: 0.2), value: controller.mode)
            // The panel is black whatever the system appearance, so AppKit
            // controls inside it must be drawn for dark.
            .environment(\.colorScheme, .dark)
    }

    /// Idle and collapsed, the panel should be invisible against the real notch.
    private var backgroundOpacity: Double {
        controller.mode == .collapsed && !store.hasAnythingToShow ? 0 : 1
    }

    @ViewBuilder private var content: some View {
        switch controller.mode {
        case .collapsed:
            CollapsedContent(
                store: store,
                metrics: controller.metrics,
                sideWidth: controller.collapsedSideWidth
            )
        case .toast:
            ToastView(toast: controller.toast, metrics: controller.metrics)
        case .expanded:
            ExpandedContent(
                store: store,
                controller: controller,
                settings: .shared,
                metrics: controller.metrics,
                width: controller.expandedWidth
            )
        }
    }
}

// MARK: - Collapsed

/// The resting state: two small clusters hugging the cutout, nothing animated.
/// The left says who is working, the right says how many threads are live.
private struct CollapsedContent: View {
    @ObservedObject var store: T3Store
    let metrics: NotchMetrics
    let sideWidth: CGFloat

    private var marked: [AgentRun] {
        store.runs.filter { $0.isWorking || $0.needsAttention }
    }

    var body: some View {
        HStack(spacing: 0) {
            DotGrid(runs: marked)
                .padding(.trailing, 9)
                .frame(width: sideWidth, alignment: .trailing)

            Color.clear.frame(width: metrics.width)

            HStack(spacing: 5) {
                counter
                if let pressure = store.contextPressure {
                    ContextPip(fraction: pressure)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .frame(width: sideWidth, alignment: .leading)
        }
        .frame(height: metrics.height)
    }

    /// Colour carries the meaning here — amber wants you, white is working,
    /// green just finished — because a glyph this small turns to mush.
    @ViewBuilder private var counter: some View {
        if store.attentionCount > 0 {
            Count(text: "\(store.attentionCount)", tint: .orange)
        } else if marked.isEmpty, store.hasUnseenFinished {
            let failed = store.finished.contains(where: \.failed)
            HStack(spacing: 3) {
                Image(systemName: failed ? "xmark" : "checkmark")
                    .font(.system(size: 9, weight: .bold))
                if store.finished.count > 1 {
                    Text("\(store.finished.count)")
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                }
            }
            .foregroundStyle(failed ? Color.red : Color.green)
        } else if !marked.isEmpty {
            Count(text: "\(marked.count)", tint: .white.opacity(0.85))
        }
    }
}

/// A four-column grid read right to left, newest first: the newest thread sits
/// closest to the cutout, older ones trail away from it and wrap onto a row
/// above. Past eight, the two oldest cells become a `+N` badge sized to exactly
/// two dots, so both rows stay the same width and the block keeps its edges.
private struct DotGrid: View {
    let runs: [AgentRun]

    private static let columns = 4
    private static let dot: CGFloat = 7
    private static let gap: CGFloat = 4
    private static let capacity = columns * 2
    /// Two cells wide: two dots and the gap between them.
    private static let badgeWidth = dot * 2 + gap
    private static let rowWidth = dot * CGFloat(columns) + gap * CGFloat(columns - 1)

    /// Newest first. Ordering here is by when the run started, not by activity,
    /// so a working agent doesn't shuffle the dots under your eyes.
    private var ordered: [AgentRun] { runs.sorted { $0.startedKey > $1.startedKey } }

    private var overflow: Int {
        ordered.count > Self.capacity ? ordered.count - (Self.capacity - 2) : 0
    }

    private var shown: [AgentRun] {
        Array(ordered.prefix(overflow > 0 ? Self.capacity - 2 : Self.capacity))
    }

    private var bottomRow: [AgentRun] { Array(shown.prefix(Self.columns)) }
    private var topRow: [AgentRun] { Array(shown.dropFirst(Self.columns)) }
    private var isTwoRows: Bool { !topRow.isEmpty }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            if isTwoRows {
                HStack(spacing: Self.gap) {
                    Spacer(minLength: 0)
                    if overflow > 0 {
                        // Sits at the far end, where the oldest threads would be.
                        Text("+\(overflow)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: Self.badgeWidth, alignment: .leading)
                    }
                    ForEach(Array(topRow.reversed())) { run in StatusDot(run: run) }
                }
            }
            HStack(spacing: Self.gap) {
                Spacer(minLength: 0)
                ForEach(Array(bottomRow.reversed())) { run in StatusDot(run: run) }
            }
        }
        .frame(width: isTwoRows ? Self.rowWidth : nil, alignment: .trailing)
    }
}

/// One thread, coloured by its phase.
private struct StatusDot: View {
    let run: AgentRun

    var body: some View {
        Circle()
            .fill(fill)
            .frame(width: 7, height: 7)
    }

    private var fill: Color {
        // Checked first so the dot always agrees with the amber count beside it:
        // a plan awaiting review makes a thread need you without changing phase.
        if run.needsAttention { return .orange }
        switch run.phase {
        case .failed: return .red
        // Spinning up: the provider's colour, dimmed until it is really working.
        case .starting: return ProviderStyle.accent(for: run.provider).opacity(0.45)
        default: return ProviderStyle.accent(for: run.provider)
        }
    }
}

/// Only appears when a thread is close to filling its context window, which is
/// the point just before T3 Code compacts and you lose the thread of it.
private struct ContextPip: View {
    let fraction: Double

    var body: some View {
        Circle()
            .strokeBorder(fraction >= ContextWindow.critical ? Color.red : Color.orange, lineWidth: 1.5)
            .frame(width: 7, height: 7)
    }
}

private struct Count: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(tint)
    }
}

// MARK: - Toast

private struct ToastView: View {
    let toast: ToastContent?
    let metrics: NotchMetrics

    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                Circle().fill(tint.opacity(0.18)).frame(width: 26, height: 26)
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(toast?.title ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(toast?.subtitle ?? "")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, metrics.height + 8)
        .padding(.bottom, 13)
    }

    private var tint: Color {
        switch toast?.kind {
        case .failed: return .red
        case .question, .approval: return .orange
        default: return .green
        }
    }

    private var symbol: String {
        switch toast?.kind {
        case .failed: return "exclamationmark.triangle.fill"
        case .question: return "questionmark"
        case .approval: return "hand.raised.fill"
        default: return "checkmark"
        }
    }
}
