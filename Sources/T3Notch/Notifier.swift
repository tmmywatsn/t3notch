import AppKit
import Combine
import Security
import ServiceManagement
import UserNotifications

/// Turns store events into a toast in the notch, plus an optional sound and
/// Notification Centre banner for when you are looking at another window.
@MainActor
final class Notifier {
    private let controller: NotchController
    private var centerAuthorized = false
    private var cancellables: Set<AnyCancellable> = []

    init(controller: NotchController) {
        self.controller = controller
        // Authorization is requested when the setting is switched on, since the
        // switch now lives in the panel rather than in a menu item we own.
        Settings.shared.$systemNotifications
            .filter { $0 }
            .sink { [weak self] _ in self?.requestSystemAuthorization() }
            .store(in: &cancellables)
    }

    func requestSystemAuthorization() {
        guard CodeSignature.isIdentified, Settings.shared.systemNotifications,
              Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                guard let self else { return }
                Task { @MainActor in self.centerAuthorized = granted }
            }
    }

    /// Fires a sample notification so you can check the notch, the sound and
    /// the banner setting without waiting for a real run.
    func preview() {
        controller.show(
            ToastContent(
                kind: .done,
                title: "Refactor the checkout flow",
                subtitle: "2m 14s · +182 −40 in 7 files · storefront"
            )
        )
        if Settings.shared.soundEnabled { NSSound(named: "Glass")?.play() }
    }

    func handle(_ event: NotchEvent) {
        Debug.log("event \(event)")
        switch event {
        case let .completed(run):
            present(
                ToastContent(kind: .done, title: run.title, subtitle: completionDetail(run)),
                sound: "Glass"
            )
        case let .failed(run):
            present(
                ToastContent(
                    kind: .failed,
                    title: run.title,
                    subtitle: run.errorText?.singleLine(limit: 80) ?? "Run failed"
                ),
                sound: "Basso"
            )
        case let .needsInput(title, question):
            present(
                ToastContent(kind: .question, title: title, subtitle: question.singleLine(limit: 80)),
                sound: "Ping"
            )
        case let .needsApproval(title):
            present(
                ToastContent(kind: .approval, title: title, subtitle: "Waiting for your approval"),
                sound: "Ping"
            )
        }
    }

    private func completionDetail(_ run: FinishedRun) -> String {
        var parts: [String] = []
        if let duration = run.duration { parts.append(duration.runDuration) }
        if run.fileCount > 0 {
            parts.append("+\(run.additions) −\(run.deletions) in \(run.fileCount) file\(run.fileCount == 1 ? "" : "s")")
        }
        if !run.projectTitle.isEmpty { parts.append(run.projectTitle) }
        return parts.isEmpty ? "Finished" : parts.joined(separator: " · ")
    }

    private func present(_ toast: ToastContent, sound: String) {
        if Settings.shared.showBanner { controller.show(toast) }
        if Settings.shared.soundEnabled { NSSound(named: sound)?.play() }
        postToNotificationCenter(toast)
    }

    private func postToNotificationCenter(_ toast: ToastContent) {
        guard Settings.shared.systemNotifications, centerAuthorized else { return }
        let content = UNMutableNotificationContent()
        content.title = toast.title
        content.body = toast.subtitle
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}

/// Preferences, held in UserDefaults and nowhere else.
@MainActor
final class Settings: ObservableObject {
    static let shared = Settings()

    private let defaults = UserDefaults.standard

    /// Drop the banner into the notch when something finishes.
    @Published var showBanner: Bool { didSet { persist(showBanner, "showBanner") } }
    @Published var soundEnabled: Bool { didSet { persist(soundEnabled, "soundEnabled") } }
    @Published var systemNotifications: Bool { didSet { persist(systemNotifications, "systemNotifications") } }
    /// Housekeeping turns finish in well under a second; off, they stay quiet.
    @Published var announceShortRuns: Bool { didSet { persist(announceShortRuns, "announceShortRuns") } }

    private init() {
        let stored = UserDefaults.standard
        func read(_ key: String, default fallback: Bool) -> Bool {
            stored.object(forKey: key) as? Bool ?? fallback
        }
        showBanner = read("showBanner", default: true)
        soundEnabled = read("soundEnabled", default: true)
        // Off by default: an ad-hoc signed build is never granted authorization.
        systemNotifications = read("systemNotifications", default: false)
        announceShortRuns = read("announceShortRuns", default: false)
    }

    private func persist(_ value: Bool, _ key: String) {
        defaults.set(value, forKey: key)
    }
}

/// Whether this build carries a real signing identity.
///
/// `build-app.sh` signs ad-hoc, which is fine for running locally but macOS
/// silently refuses notification authorization and login-item registration to
/// unidentified apps. Rather than offer switches that quietly do nothing, the
/// settings that depend on a Developer ID are hidden until there is one.
enum CodeSignature {
    static let isIdentified: Bool = {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let signing = info as? [String: Any] else { return false }
        let adhoc = ((signing[kSecCodeInfoFlags as String] as? UInt32) ?? 0) & 0x2 != 0
        let certificates = (signing[kSecCodeInfoCertificates as String] as? [Any])?.count ?? 0
        return !adhoc && certificates > 0
    }()
}

/// "Start at login", which macOS tracks itself rather than in our preferences.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Unsigned builds cannot register, so callers re-read `isEnabled` rather
    /// than assuming the request took.
    static func set(_ enabled: Bool) {
        if enabled {
            try? SMAppService.mainApp.register()
        } else {
            try? SMAppService.mainApp.unregister()
        }
    }
}
