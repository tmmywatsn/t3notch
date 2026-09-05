import AppKit
import SwiftUI

/// Provider colours and names, taken from T3 Code's own settings so the notch
/// matches whatever accent you picked in the app.
enum ProviderStyle {
    private static let accents: [String: Color] = {
        let settings = T3Paths.userData.appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: settings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let instances = root["providerInstances"] as? [String: Any]
        else { return [:] }
        var result: [String: Color] = [:]
        for (key, value) in instances {
            guard let config = value as? [String: Any],
                  let hex = config["accentColor"] as? String,
                  let color = Color(hex: hex) else { continue }
            result[key] = color
        }
        return result
    }()

    private static let fallbacks: [String: Color] = [
        "claudeAgent": Color(red: 0.92, green: 0.35, blue: 0.10),
        "codex": Color(red: 0.55, green: 0.78, blue: 1.0),
        "cursor": Color(red: 0.65, green: 0.55, blue: 0.98),
        "opencode": Color(red: 0.40, green: 0.85, blue: 0.65)
    ]

    static func accent(for provider: String?) -> Color {
        guard let provider else { return .gray }
        return accents[provider] ?? fallbacks[provider] ?? .gray
    }

    static func name(for provider: String?) -> String {
        switch provider {
        case "claudeAgent": return "Claude"
        case "codex": return "Codex"
        case "cursor": return "Cursor"
        case "opencode": return "opencode"
        case let other?: return other.capitalized
        case nil: return "Agent"
        }
    }
}

extension Color {
    init?(hex: String) {
        var value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if value.count == 3 { value = value.map { "\($0)\($0)" }.joined() }
        guard value.count == 6, let number = UInt32(value, radix: 16) else { return nil }
        self.init(
            red: Double((number >> 16) & 0xFF) / 255,
            green: Double((number >> 8) & 0xFF) / 255,
            blue: Double(number & 0xFF) / 255
        )
    }
}

enum T3Code {
    static let bundleIdentifier = "com.t3tools.t3code"

    /// Brings T3 Code forward; the notch is for glancing, the app is for acting.
    static func activate() {
        let workspace = NSWorkspace.shared
        guard let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        workspace.openApplication(at: url, configuration: configuration)
    }
}
