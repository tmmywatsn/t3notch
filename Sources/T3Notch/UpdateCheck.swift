import AppKit
import Combine
import Foundation

/// A dotted version, compared number by number so that 1.10.0 sorts above
/// 1.9.0 — which string comparison gets backwards.
struct AppVersion: Comparable, CustomStringConvertible {
    let components: [Int]

    /// Accepts "1.2.0", "v1.2.0" and "1.2.0-beta.1". A pre-release or build
    /// suffix is dropped rather than ranked, since releases here never carry
    /// one and guessing at an order would be worse than ignoring it.
    init?(_ string: String) {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[text.startIndex..<cut])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 4 else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard let value = Int(part), value >= 0 else { return nil }
            numbers.append(value)
        }
        components = numbers
    }

    /// Missing trailing components read as zero, so 1.2 and 1.2.0 are the same
    /// version rather than merely neither-less-than-the-other.
    private static func compare(_ lhs: AppVersion, _ rhs: AppVersion) -> Int {
        for index in 0..<max(lhs.components.count, rhs.components.count) {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right ? -1 : 1 }
        }
        return 0
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) < 0 }
    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool { compare(lhs, rhs) == 0 }

    var description: String { components.map(String.init).joined(separator: ".") }

    /// What this build reports, from Info.plist.
    static let current = AppVersion(
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    )

    /// The same, plus a commit for builds that aren't sitting on a release tag.
    static let currentBuild = Bundle.main.infoDictionary?["T3NotchBuild"] as? String
        ?? current?.description ?? "unknown"
}

/// Asks GitHub, once a day at most, whether a newer release has been tagged.
///
/// This is the only outbound request the app makes, it carries no identifier
/// beyond a version in the User-Agent, and it does not run at all while
/// `Settings.checkForUpdates` is off.
@MainActor
final class UpdateChecker: ObservableObject {
    struct Release {
        let version: AppVersion
        let page: URL
    }

    static let shared = UpdateChecker()

    /// Set only when the tagged release is strictly newer than this build.
    @Published private(set) var available: Release?

    private static let endpoint = URL(
        string: "https://api.github.com/repos/tmmywatsn/t3notch/releases/latest"
    )!
    private static let interval: TimeInterval = 60 * 60 * 24
    private let lastCheckKey = "lastUpdateCheck"

    private var timer: Timer?
    private var inFlight = false
    private var cancellables: Set<AnyCancellable> = []

    /// Ephemeral, so nothing about the request touches the disk.
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpCookieStorage = nil
        config.urlCache = nil
        return URLSession(configuration: config)
    }()

    private init() {}

    func start() {
        // The update UI is otherwise only reachable when a real release is
        // newer than this build, which is impossible to arrange while working
        // on it. T3NOTCH_FAKE_UPDATE=1.2.0 stands one in.
        if let fake = ProcessInfo.processInfo.environment["T3NOTCH_FAKE_UPDATE"],
           let version = AppVersion(fake) {
            available = Release(
                version: version,
                page: URL(string: "https://github.com/tmmywatsn/t3notch/releases/latest")!
            )
            return
        }

        Settings.shared.$checkForUpdates
            .sink { [weak self] enabled in
                guard let self else { return }
                Task { @MainActor in
                    if enabled { self.checkIfDue() } else { self.available = nil }
                }
            }
            .store(in: &cancellables)

        // Ticks hourly; checkIfDue is what enforces the daily interval, so a
        // Mac that sleeps through its slot checks shortly after it wakes.
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in self.checkIfDue() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        guard last.map({ Date().timeIntervalSince($0) >= Self.interval }) ?? true else { return }
        check()
    }

    /// Ignores the interval; used by the "Check now" button.
    func check() {
        guard Settings.shared.checkForUpdates, !inFlight, let current = AppVersion.current else { return }
        inFlight = true

        var request = URLRequest(url: Self.endpoint)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("T3Notch/\(current)", forHTTPHeaderField: "User-Agent")

        session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let release = Self.parse(data: data, response: response, error: error, current: current)
            Task { @MainActor in
                self.inFlight = false
                UserDefaults.standard.set(Date(), forKey: self.lastCheckKey)
                if let release { self.available = release }
                Debug.log("update check \(current) -> \(release.map { "\($0.version)" } ?? "up to date")")
            }
        }.resume()
    }

    /// Split out from the request so the parsing is exercised by the tests.
    /// Returns a release only when it is newer than `current`.
    nonisolated static func parse(
        data: Data?,
        response: URLResponse?,
        error: Error?,
        current: AppVersion
    ) -> Release? {
        guard error == nil,
              (response as? HTTPURLResponse)?.statusCode == 200,
              let data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              // /releases/latest already excludes drafts and pre-releases, but
              // the flags are cheap to honour if that ever changes.
              (json["draft"] as? Bool) != true,
              (json["prerelease"] as? Bool) != true,
              let tag = json["tag_name"] as? String,
              let version = AppVersion(tag),
              version > current
        else { return nil }

        let page = (json["html_url"] as? String).flatMap(URL.init(string:))
            ?? URL(string: "https://github.com/tmmywatsn/t3notch/releases/latest")!
        return Release(version: version, page: page)
    }
}
