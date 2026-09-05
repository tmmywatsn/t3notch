import AppKit

let application = NSApplication.shared
// Menu bar only: no Dock icon, no app switcher entry.
application.setActivationPolicy(.accessory)

// NSApplication holds its delegate weakly, so this global keeps it alive.
let delegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = delegate
application.run()
