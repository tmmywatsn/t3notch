import AppKit
import SwiftUI

struct ToastContent: Equatable {
    enum Kind: Equatable { case done, failed, question, approval }
    let kind: Kind
    let title: String
    let subtitle: String
}

/// A borderless panel pinned to the notch that never takes focus.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        // Above the menu bar, and present on every Space including full screen.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
}

/// Owns the panel and decides how big it should be right now.
@MainActor
final class NotchController: ObservableObject {
    enum Mode: Equatable {
        case collapsed
        case toast
        case expanded
    }

    @Published private(set) var mode: Mode = .collapsed
    @Published private(set) var toast: ToastContent?
    /// Swaps the expanded panel's body for the preferences list.
    @Published var showingSettings = false
    @Published var metrics: NotchMetrics

    /// How far the shape's top corners flare into the menu bar.
    let flare: CGFloat = 9
    let expandedWidth: CGFloat = 460
    let toastWidth: CGFloat = 380
    /// Menu bar space claimed on each side of the cutout while collapsed. Wide
    /// enough for four dots or a count, narrow enough to stay clear of the app
    /// menus on the left and the status items on the right.
    let collapsedSideWidth: CGFloat = 62

    private var panel: NotchPanel?
    private let store: T3Store
    private var toastDismissal: Timer?
    private var hoverTimer: Timer?
    private var measuredHeight: CGFloat = 0
    /// The footprint the cursor has to leave before the panel closes.
    ///
    /// It follows the panel down only once the cursor is back inside it, so a
    /// panel that shrinks under a stationary cursor — opening settings, a run
    /// finishing — doesn't yank itself closed.
    private var stickyFrame: NSRect = .zero
    private var screenObserver: Any?

    init(store: T3Store, metrics: NotchMetrics) {
        self.store = store
        self.metrics = metrics
    }

    func present() {
        let bounds = frame(for: .collapsed)
        let panel = NotchPanel(contentRect: bounds)
        let hosting = NSHostingView(rootView: NotchRootView(store: store, controller: self))
        // Left to itself, NSHostingView constrains the window to the SwiftUI
        // content's ideal size, which fights the frames we set here and makes
        // hover flap between states. We size the window; it just fills it.
        hosting.sizingOptions = []
        hosting.frame = CGRect(origin: .zero, size: bounds.size)
        hosting.autoresizingMask = [.width, .height]
        let container = NSView(frame: CGRect(origin: .zero, size: bounds.size))
        container.autoresizesSubviews = true
        container.addSubview(hosting)
        panel.contentView = container
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        self.panel = panel
        applyFrame(animated: false)

        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollCursor() }
        }

        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.screensChanged() }
        }
    }

    private func screensChanged() {
        guard let updated = NotchMetrics.current() else { return }
        metrics = updated
        applyFrame(animated: false)
    }

    // MARK: - Hover

    /// Hover is tracked by polling the cursor rather than with SwiftUI's
    /// `onHover`: expanding swaps the view subtree, which re-fires `onHover` and
    /// sends the panel into a collapse/expand loop. Polling the cursor against
    /// the panel's own geometry has no such feedback, and lets the entry and
    /// exit regions differ so the panel doesn't flicker at its own edge.
    /// Deliberately narrower than the collapsed panel: the indicators may sit
    /// well out into the menu bar, but only the cutout itself should open it.
    private var hoverZone: NSRect {
        NSRect(
            x: metrics.notch.minX - 18,
            y: metrics.topY - metrics.height,
            width: metrics.width + 36,
            height: metrics.height
        )
    }

    private func pollCursor() {
        let cursor = NSEvent.mouseLocation
        switch mode {
        case .collapsed, .toast:
            if hoverZone.contains(cursor) {
                hoverChanged(true)
            }
        case .expanded:
            let live = frame(for: .expanded).insetBy(dx: -8, dy: -8)
            if live.contains(cursor) {
                stickyFrame = live
            } else if !stickyFrame.contains(cursor) {
                hoverChanged(false)
            }
        }
    }

    // MARK: - Mode changes

    func hoverChanged(_ hovering: Bool) {
        if hovering {
            stickyFrame = frame(for: .expanded)
            store.markFinishedSeen()
            toastDismissal?.invalidate()
            toast = nil
            setMode(.expanded)
        } else if mode == .expanded {
            setMode(.collapsed)
            store.clearSeenFinished()
            showingSettings = false
        }
    }

    func show(_ content: ToastContent, for duration: TimeInterval = 4.5) {
        guard mode != .expanded else { return }
        toast = content
        setMode(.toast)
        toastDismissal?.invalidate()
        toastDismissal = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode == .toast else { return }
                self.toast = nil
                self.setMode(.collapsed)
            }
        }
    }

    func toggleExpanded() {
        setMode(mode == .expanded ? .collapsed : .expanded)
    }

    func toggleSettings() {
        showingSettings.toggle()
    }

    private func setMode(_ newMode: Mode) {
        guard mode != newMode else { return }
        mode = newMode
        // Collapsed, the panel spills over menu bar space it does not own, so it
        // must not eat clicks. Hover is polled from the cursor position, so
        // nothing depends on the window receiving mouse events.
        panel?.ignoresMouseEvents = newMode != .expanded
        applyFrame(animated: true)
    }

    /// SwiftUI reports the panel's natural height; the window follows it.
    func contentHeightChanged(_ height: CGFloat) {
        // Collapsed height is fixed, and recording it would make the next
        // expansion animate from the wrong size.
        Debug.log("height report \(height) mode=\(mode)")
        guard mode != .collapsed else { return }
        let clamped = min(max(height, metrics.height), 520)
        guard abs(clamped - measuredHeight) > 0.5 else { return }
        measuredHeight = clamped
        applyFrame(animated: true)
    }

    // MARK: - Geometry

    func cardSize(for mode: Mode) -> CGSize {
        switch mode {
        case .collapsed:
            // Exactly the menu bar's height, so the panel reads as the cutout
            // widening rather than as a box sitting on top of the menu bar.
            return CGSize(width: metrics.width + collapsedSideWidth * 2, height: metrics.height)
        case .toast:
            return CGSize(width: toastWidth, height: max(measuredHeight, metrics.height + 52))
        case .expanded:
            return CGSize(width: expandedWidth, height: max(measuredHeight, metrics.height + 80))
        }
    }

    private func frame(for mode: Mode) -> NSRect {
        let size = cardSize(for: mode)
        let width = size.width + flare * 2
        return NSRect(
            x: (metrics.centerX - width / 2).rounded(),
            y: (metrics.topY - size.height).rounded(),
            width: width.rounded(),
            height: size.height.rounded()
        )
    }

    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        let target = frame(for: mode)
        Debug.log("frame mode=\(mode) target=\(target) actual=\(panel.frame)")
        guard panel.frame != target else { return }
        if mode == .expanded {
            stickyFrame = stickyFrame.union(target).union(panel.frame)
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.24
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }
    }
}
