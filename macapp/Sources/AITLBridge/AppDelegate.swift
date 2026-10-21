import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let supervisor = Supervisor()
    private var timer: Timer?
    private var window: NSWindow?
    private let deviceModel = DeviceModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.toolTip = "AITL Bridge"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        supervisor.onChange = { [weak self] in self?.updateIcon() }
        updateIcon()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        supervisor.start()
        buildMainMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.openWindow() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.supervisor.refresh() }
    }

    func applicationWillTerminate(_ notification: Notification) { supervisor.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }   // closing the window keeps the bridge alive in the menu bar

    /// Standard app menu so ⌘Q, ⌘W, copy/paste and Settings work like any Mac app.
    private func buildMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About AITL Bridge", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "AITL Manager…", action: #selector(openWindow), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide AITL Bridge", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit AITL Bridge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.mainMenu = main
    }

    // MARK: icon
    private func updateIcon() {
        guard let button = statusItem.button else { return }
        let st = supervisor.status
        let name = !st.running ? "dot.radiowaves.left.and.right" : st.devices.isEmpty ? "dot.radiowaves.left.and.right" : "dot.radiowaves.up.forward"
        let img = NSImage(systemSymbolName: name, accessibilityDescription: "AITL")
        img?.isTemplate = true
        button.image = img
        let n = Set(st.devices.map { $0.id }).count
        button.title = n > 0 ? " \(n)" : ""
        button.appearsDisabled = !st.running
    }

    // MARK: menu
    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()
        let st = supervisor.status
        if !supervisor.runtimeInstalled {
            menu.addItem(disabled("Bridge runtime not installed"))
            menu.addItem(disabled("Run in the project:  cd bridge && aitl install-app"))
        } else {
            menu.addItem(disabled(st.running ? "Bridge running" : "Bridge stopped"))
            if st.running {
                let ids = Dictionary(grouping: st.devices, by: { $0.id })
                if ids.isEmpty { menu.addItem(disabled("   no device linked (USB, Bluetooth or Wi-Fi)")) }
                for (id, list) in ids.sorted(by: { $0.key < $1.key }) {
                    let via = list.map { $0.transport }.sorted().joined(separator: " + ")
                    let model = list.first?.model ?? ""
                    menu.addItem(disabled("   ● \(id.suffix(6))  via \(via)   \(model)"))
                }
                if let ok = st.macControl {
                    if ok { menu.addItem(disabled("   Mac control: allowed")) }
                    else {
                        let fix = NSMenuItem(title: "   Mac control blocked – open Accessibility settings…", action: #selector(openAccessibility), keyEquivalent: "")
                        fix.target = self; menu.addItem(fix)
                    }
                }
            }
        }
        menu.addItem(.separator())
        menu.addItem(item("Open AITL Manager…", #selector(openWindow), key: "o"))
        menu.addItem(item(st.running ? "Restart Bridge" : "Start Bridge", #selector(toggleBridge)))
        if st.running { menu.addItem(item("Stop Bridge", #selector(stopBridge))) }
        menu.addItem(.separator())
        menu.addItem(item("Open Wi-Fi Pairing Window (3 min)…", #selector(pairWifi)))
        menu.addItem(item("Install Claude Code Hooks", #selector(installHooks)))
        menu.addItem(item("Update Runtime from Project", #selector(updateRuntime)))
        menu.addItem(.separator())
        menu.addItem(item("Open Log", #selector(openLog)))
        menu.addItem(item("Edit config.toml", #selector(openConfig)))
        menu.addItem(item("Open Accessibility Settings…", #selector(openAccessibility)))
        menu.addItem(.separator())
        let login = item("Launch at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(item("Quit AITL Bridge", #selector(quit), key: "q"))
    }

    private func disabled(_ title: String) -> NSMenuItem { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.isEnabled = false; return i }
    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem { let i = NSMenuItem(title: title, action: sel, keyEquivalent: key); i.target = self; return i }

    // MARK: actions
    @objc func openWindow() {
        if window == nil {
            let root = SettingsView(model: deviceModel, supervisor: supervisor)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "AITL Manager"
            w.contentView = NSHostingView(rootView: root)
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        deviceModel.refresh()
    }

    @objc private func toggleBridge() { supervisor.status.running ? supervisor.restart() : supervisor.start() }
    @objc private func stopBridge() { supervisor.stop() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openLog() { NSWorkspace.shared.open(Supervisor.logURL) }
    @objc private func openConfig() { NSWorkspace.shared.open(Supervisor.configURL) }
    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
    }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch { notify("Launch at login", error.localizedDescription) }
    }
    @objc private func installHooks() {
        let out = supervisor.runCLI(["hooks", "install"])
        notify("Claude Code hooks", out.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "installed" : String(out.prefix(180)))
    }
    @objc private func updateRuntime() {
        let projectFile = Supervisor.configDir.appendingPathComponent("project_path")
        guard let project = try? String(contentsOf: projectFile).trimmingCharacters(in: .whitespacesAndNewlines) else {
            notify("Update runtime", "Run `aitl install-app` once from the project so the app knows where it lives."); return
        }
        let venv = URL(fileURLWithPath: project).appendingPathComponent(".venv/bin/python")
        let p = Process(); p.executableURL = venv; p.arguments = ["-m", "aitl_bridge.cli", "install-app"]
        p.currentDirectoryURL = URL(fileURLWithPath: project)
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run(); p.waitUntilExit() } catch { notify("Update runtime", error.localizedDescription); return }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        notify("Update runtime", String(out.suffix(160)))
        supervisor.restart()
    }
    @objc private func pairWifi() {
        supervisor.openPairingWindow { [weak self] fp in
            guard let self else { return }
            let alert = NSAlert()
            alert.messageText = fp == nil ? "Bridge not running" : "Wi-Fi pairing window open (3 minutes)"
            alert.informativeText = fp.map { "On the device: Setup › Pair over network. Accept only if the device shows this fingerprint:\n\n\($0)" } ?? "Start the bridge first."
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent(); c.title = title; c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) { rebuildMenu() }
}
