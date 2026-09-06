import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = T3Store()
    private var controller: NotchController?
    private var notifier: Notifier?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let metrics = NotchMetrics.current() else {
            Debug.log("no screen to attach to; quitting")
            NSApp.terminate(nil)
            return
        }

        let controller = NotchController(store: store, metrics: metrics)
        let notifier = Notifier(controller: controller)
        self.controller = controller
        self.notifier = notifier

        store.onEvent = { [weak notifier] event in notifier?.handle(event) }
        controller.present()
        notifier.requestSystemAuthorization()
        store.start()
        UpdateChecker.shared.start()
        installStatusItem()
        // Explains why the signature-dependent settings are or aren't showing.
        Debug.log("signed identity=\(CodeSignature.isIdentified) loginItem=\(SMAppService.mainApp.status.rawValue)")

        if ProcessInfo.processInfo.environment["T3NOTCH_PREVIEW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak notifier] in
                notifier?.preview()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store.stop()
        UpdateChecker.shared.stop()
    }

    // MARK: - Menu bar item

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(
            systemSymbolName: "rectangle.topthird.inset.filled",
            accessibilityDescription: "T3 Notch"
        )
        item.button?.image?.isTemplate = true
        item.menu = buildMenu()
        statusItem = item
    }

    /// Deliberately carries no preferences: settings live in the panel, and
    /// duplicating them here meant two lists that drifted apart.
    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open T3 Code", action: #selector(openT3Code), keyEquivalent: "")
        menu.addItem(withTitle: "Show the notch panel", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Preview a notification", action: #selector(previewNotification), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit T3 Notch", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        for item in menu.items where item.action != nil && item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        return menu
    }

    @objc private func openT3Code() { T3Code.activate() }

    @objc private func togglePanel() { controller?.toggleExpanded() }

    @objc private func previewNotification() { notifier?.preview() }
}
