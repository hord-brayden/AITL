import AppKit

// Top-level code runs on the main thread; hop onto the main actor explicitly for the delegate.
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.regular)   // a real app: Dock icon, main window, plus the menu-bar item
app.run()
