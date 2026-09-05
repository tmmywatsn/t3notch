import Foundation

/// Diagnostics behind `T3NOTCH_DEBUG=1`, written to stderr.
enum Debug {
    static let isEnabled = ProcessInfo.processInfo.environment["T3NOTCH_DEBUG"] == "1"

    /// The message is an autoclosure because this is called from the layout
    /// path, where building a string that is then thrown away is pure waste.
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled, let line = "notch: \(message())\n".data(using: .utf8) else { return }
        FileHandle.standardError.write(line)
    }
}
