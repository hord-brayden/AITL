import SwiftUI
import ApplicationServices

/// The management window: everything on the device's Setup screen, plus Wi-Fi provisioning and model choice.
struct SettingsView: View {
    @ObservedObject var model: DeviceModel
    let supervisor: Supervisor
    @State private var ssid = ""
    @State private var password = ""
    @State private var provisionResult = ""
    @State private var selectedModel = ""
    @State private var hostChoice = "mdns"
    @State private var customHost = ""
    @State private var notifyResult = ""
    @State private var netResult = ""
    @State private var bleResult = ""
    @State private var ntfyTopic = ""
    @State private var ntfyURL = ""
    @State private var ntfyToken = ""
    @State private var ntfyResult = ""
    @State private var ntfyLoaded = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 230)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if model.settings.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("No device linked").font(.title2.weight(.semibold))
                            Text(model.error.isEmpty ? "Plug the device in over USB, or link it over Bluetooth or Wi-Fi." : model.error).foregroundStyle(.secondary)
                            Button("Refresh") { model.refresh() }
                        }.padding(.top, 8)
                    } else {
                        section("Model") { modelPicker }
                        section("Wi-Fi networks") { networksPanel }
                        section("Bridge link over Wi-Fi") { wifiPanel }
                        section("Display") { displayPanel }
                        section("Touch") { touchPanel }
                        section("Dictation") { dictationPanel }
                        section("Bluetooth & keystrokes") { blePanel }
                        section("Notifications → device") { notificationsPanel }
                        section("Phone push (ntfy)") { ntfyPanel }
                        section("Hardware (case add-ons)") { hardwarePanel }
                        section("Storage & maintenance") { maintenancePanel }
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .onAppear { model.refresh(); selectedModel = model.str("model") }
        .onReceive(Timer.publish(every: 6, on: .main, in: .common).autoconnect()) { _ in model.refresh() }
        .onChange(of: model.settings["model"] as? String ?? "") { v in selectedModel = v }
    }

    // MARK: sidebar (status)
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "dot.radiowaves.up.forward").font(.title2).foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AITL").font(.headline).tracking(3)
                    Text("CAERULI OBSCURI LAB").font(.caption2).foregroundStyle(.secondary).tracking(1)
                }
            }.padding(.bottom, 6)
            statusRow("Bridge", supervisor.status.running ? "running" : "stopped", supervisor.status.running ? .green : .orange)
            statusRow("Device", model.settings.isEmpty ? "none" : model.str("board") + "  fw " + model.str("fw"), model.settings.isEmpty ? .orange : .green)
            if !model.settings.isEmpty {
                statusRow("ID", model.deviceId, .secondary)
                statusRow("Links", Dictionary(grouping: supervisor.status.devices, by: { $0.transport }).keys.sorted().joined(separator: " + "), .green)
                statusRow("Free RAM", "\(model.int("heap") / 1024) KB", model.int("heap") < 30000 ? .orange : .secondary)
                statusRow("Wi-Fi", model.str("wifiStatus"), .secondary)
                statusRow("Bridge link", model.str("bridgeStatus"), .secondary)
                statusRow("microSD", model.str("sd"), .secondary)
                statusRow("Last reset", model.str("reset").isEmpty ? "-" : model.str("reset"), ["panic", "watchdog", "brownout", "task-wdt", "int-wdt"].contains(model.str("reset")) ? .orange : .secondary)
                if model.bool("batteryEnabled") { statusRow("Battery", "\(model.int("batteryPct"))%  (\(model.int("batteryMv")) mV)", model.int("batteryPct") < 15 ? .orange : .secondary) }
            }
            statusRow("App trusted (AX)", AXIsProcessTrusted() ? "yes" : "no", AXIsProcessTrusted() ? .green : .red)
            if let ok = supervisor.status.macControl {
                statusRow("Mac control", ok ? "allowed" : "blocked: grant Accessibility", ok ? .green : .red)
                if !ok {
                    Button("Grant Accessibility…") {
                        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
                        _ = AXIsProcessTrustedWithOptions(opts)
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            Spacer()
            if !model.lastMessage.isEmpty { Text(model.lastMessage).font(.caption).foregroundStyle(.secondary) }
            if !model.error.isEmpty && !model.settings.isEmpty { Text(model.error).font(.caption).foregroundStyle(.red) }
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }.buttonStyle(.bordered).controlSize(.small)
        }
        .padding(18)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
    }
    private func statusRow(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k.uppercased()).font(.caption2).foregroundStyle(.secondary).tracking(1)
            Text(v).font(.callout).foregroundStyle(c == .secondary ? Color.primary : c).lineLimit(2)
        }
    }

    // MARK: panels
    private func section<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        GroupBox(label: Text(title).font(.headline)) {
            VStack(alignment: .leading, spacing: 12) { content() }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Model used on the device", selection: $selectedModel) {
                ForEach(model.models.filter { $0.ok }) { m in Text("\(m.label)  ·  \(m.provider)").tag(m.id) }
            }
            .onChange(of: selectedModel) { v in if !v.isEmpty && v != model.str("model") { model.set("model", v, note: "Model set to \(v)") } }
            Text("Claude (Code) models run on your Claude Code login; Gemini needs GEMINI_API_KEY or `aitl keys set gemini`; Ollama models are local.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var wifiPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Wi-Fi on (restarts the device; Bluetooth parks while Wi-Fi is on)", isOn: Binding(get: { model.bool("wifiEnabled") }, set: { model.set("wifiEnabled", $0) }))
            HStack {
                TextField("Network name (2.4 GHz)", text: $ssid).textFieldStyle(.roundedBorder).frame(width: 220)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Send Wi-Fi + bridge pairing over USB") {
                    model.provision(ssid: ssid, password: password, bridge: true, host: chosenHost) { provisionResult = $0; password = "" }
                }.disabled(ssid.isEmpty || model.busy)
            }
            HStack {
                Picker("Device reaches this Mac at", selection: $hostChoice) {
                    Text("aitl-bridge.local (mDNS, auto)").tag("mdns")
                    if let lan = hosts["lan"], !lan.isEmpty { Text("LAN IP \(lan)").tag("lan") }
                    if let ts = hosts["tailscale"], !ts.isEmpty { Text("Tailscale \(ts)").tag("tailscale") }
                    Text("Custom…").tag("custom")
                }.frame(width: 360)
                if hostChoice == "custom" { TextField("host or IP", text: $customHost).textFieldStyle(.roundedBorder).frame(width: 180) }
            }
            HStack {
                Button("Re-pair bridge only (new address / token)") { model.provision(ssid: nil, password: nil, bridge: true, host: chosenHost) { provisionResult = $0 } }.disabled(model.busy)
                Text("Current: \(model.str("wifiSsid").isEmpty ? "none" : model.str("wifiSsid"))  →  \(model.str("bridgeHost")):\(model.int("bridgePort"))  (\(model.int("wifiMode") == 1 ? "TLS" : "signed frames"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !provisionResult.isEmpty { Text(provisionResult).font(.caption) }
            Text("The device must be able to reach this Mac: same network for mDNS/LAN IP. The Tailscale address only works if the device's network routes into your tailnet (a Tailscale subnet router on that LAN); the ESP32 cannot join a tailnet itself. Provisioning only goes over the USB cable. Wi-Fi frames are HMAC-signed with a per-session nonce; the password and token never travel over the air.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Wi-Fi network table
    private var networksPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.networks.isEmpty {
                Text("No saved networks yet. Add one below (the password goes to the device over USB only).").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(model.networks) { n in
                    HStack(spacing: 10) {
                        Image(systemName: n.current ? "wifi" : "wifi.slash").foregroundStyle(n.current ? .green : .secondary).frame(width: 18)
                        Text(n.ssid).fontWeight(n.current ? .semibold : .regular).frame(width: 220, alignment: .leading)
                        Text(n.current ? "current" : "saved").font(.caption).foregroundStyle(.secondary).frame(width: 60, alignment: .leading)
                        Stepper("prio \(n.prio)", onIncrement: { model.wifi("wifi_add", ssid: n.ssid, password: "", prio: n.prio + 1) }, onDecrement: { model.wifi("wifi_add", ssid: n.ssid, password: "", prio: n.prio - 1) })
                            .frame(width: 110).disabled(true).help("Priority is set when adding; re-add to change it")
                        Button("Use now") { model.wifi("wifi_use", ssid: n.ssid) { netResult = $0.isEmpty ? "Switching to \(n.ssid)…" : $0 } }.disabled(n.current || model.busy)
                        Button("Forget") { model.wifi("wifi_remove", ssid: n.ssid) { netResult = $0.isEmpty ? "Forgot \(n.ssid)" : $0 } }.disabled(model.busy)
                    }
                }
            }
            Divider()
            HStack {
                TextField("Network name (2.4 GHz)", text: $ssid).textFieldStyle(.roundedBorder).frame(width: 220)
                SecureField("Password", text: $password).textFieldStyle(.roundedBorder).frame(width: 200)
                Button("Save to device (USB)") {
                    model.wifi("wifi_add", ssid: ssid, password: password) { netResult = $0; password = ""; if !$0.hasPrefix("Failed") { ssid = "" } }
                }.disabled(ssid.isEmpty || model.busy)
                Button(model.scanning ? "Scanning…" : "Scan nearby") { model.wifiScan() }.disabled(model.scanning || model.busy)
            }
            if !model.scan.isEmpty {
                HStack(spacing: 6) {
                    Text("Seen:").font(.caption).foregroundStyle(.secondary)
                    ForEach(model.scan.prefix(10)) { n in
                        Button("\(n.ssid)  \(n.rssi) dBm") { ssid = n.ssid }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if !netResult.isEmpty { Text(netResult).font(.caption) }
            Text("The device keeps up to 8 networks and, on boot or reconnect, joins the strongest one it can see (priority breaks ties). Scanning briefly pauses the link.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: phone push
    private var ntfyPanel: some View {
        let enabled = model.ntfy["enabled"] as? Bool ?? false
        let actions = model.ntfy["actions"] as? String ?? ""
        let events = Set(model.ntfy["events"] as? [String] ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: enabled ? "checkmark.circle.fill" : "iphone.slash").foregroundStyle(enabled ? .green : .secondary)
                Text(enabled ? "Pushing to \(model.ntfy["url"] as? String ?? "")/\(model.ntfy["topic"] as? String ?? "")" : "Off. Install the ntfy app on your phone, subscribe to a topic, and enter it here.")
            }
            HStack {
                TextField("Server", text: $ntfyURL).textFieldStyle(.roundedBorder).frame(width: 220)
                TextField("Topic (treat it like a password)", text: $ntfyTopic).textFieldStyle(.roundedBorder).frame(width: 260)
                Button("Save") {
                    model.configSet("ntfy", "url", ntfyURL.isEmpty ? "https://ntfy.sh" : ntfyURL) { _ in
                        model.configSet("ntfy", "topic", ntfyTopic) { ok in ntfyResult = ok ? "Saved. Forwarding \(ntfyTopic.isEmpty ? "off" : "on")." : "Save failed" }
                    }
                }
            }
            HStack {
                SecureField("Access token (optional, for a protected topic)", text: $ntfyToken).textFieldStyle(.roundedBorder).frame(width: 330)
                Button("Store in Keychain") { model.keySet("ntfy", ntfyToken) { ok in ntfyResult = ok ? "Token stored" : "Keychain write failed"; ntfyToken = "" } }.disabled(ntfyToken.isEmpty)
                if model.ntfy["token"] as? Bool == true { Text("token set").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 14) {
                ForEach([("permission", "Permission prompts"), ("notify", "Needs input"), ("done", "Turn finished"), ("notice", "macOS notifications")], id: \.0) { ev in
                    Toggle(ev.1, isOn: Binding(get: { events.contains(ev.0) }, set: { on in
                        var e = events; if on { e.insert(ev.0) } else { e.remove(ev.0) }
                        model.configSet("ntfy", "events", Array(e).sorted())
                    })).toggleStyle(.checkbox)
                }
            }
            HStack {
                Button("Send test push") { model.ntfyTest { ntfyResult = $0 } }.disabled(!enabled)
                Text(ntfyResult).font(.caption).foregroundStyle(.secondary)
            }
            Text(actions.isEmpty
                 ? "Allow/Deny buttons on phone pushes need Tailscale running on this Mac (the bridge binds the action server to your Tailscale IP only, with a secret in each link)."
                 : "Allow/Deny buttons answer through \(actions) (Tailscale-only, secret-signed links). Permission prompts still fall back to the terminal after the timeout.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { if !ntfyLoaded { ntfyURL = model.ntfy["url"] as? String ?? "https://ntfy.sh"; ntfyTopic = model.ntfy["topic"] as? String ?? ""; ntfyLoaded = true } }
        .onChange(of: model.ntfy["topic"] as? String ?? "") { v in if ntfyTopic.isEmpty { ntfyTopic = v } }
    }

    // MARK: hardware add-ons (INMP441, encoder, toggle, battery, speaker)
    private func gpioField(_ label: String, _ key: String) -> some View {
        HStack(spacing: 4) {
            Text(label).font(.caption)
            TextField("", value: Binding(get: { model.int(key) }, set: { model.set(key, $0) }), format: .number).textFieldStyle(.roundedBorder).frame(width: 46)
        }
    }
    private var hardwarePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) { Text("INMP441 mic").frame(width: 110, alignment: .leading); gpioField("SCK", "micSck"); gpioField("WS", "micWs"); gpioField("SD", "micSd"); Text("L/R to GND, 3.3 V. -1 disables.").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 14) { Text("Rotary encoder").frame(width: 110, alignment: .leading); gpioField("A", "encA"); gpioField("B", "encB"); gpioField("SW", "encSw"); Text("Turn scrolls, press = dictate.").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing: 14) {
                Text("Toggle switch").frame(width: 110, alignment: .leading); gpioField("pin", "togglePin")
                Picker("", selection: Binding(get: { model.int("toggleRole") }, set: { model.set("toggleRole", $0) })) {
                    Text("Privacy (mic off)").tag(0); Text("Screen off").tag(1); Text("Glance mode").tag(2)
                }.frame(width: 190)
            }
            HStack(spacing: 14) {
                Toggle("Battery gauge on GPIO34", isOn: Binding(get: { model.bool("batteryEnabled") }, set: { model.set("batteryEnabled", $0) }))
                Stepper("divider ×\(Double(model.int("batteryDivider")) / 1000, specifier: "%.2f")", onIncrement: { model.set("batteryDivider", min(4000, model.int("batteryDivider") + 100)) }, onDecrement: { model.set("batteryDivider", max(1000, model.int("batteryDivider") - 100)) }).frame(width: 170)
                if model.bool("batteryEnabled") { Text("\(model.int("batteryPct"))%  \(model.int("batteryMv")) mV").font(.caption).foregroundStyle(.secondary) }
            }
            HStack(spacing: 14) {
                Picker("Speaker chime", selection: Binding(get: { model.int("chime") }, set: { model.set("chime", $0) })) { Text("Off").tag(0); Text("Prompts only").tag(1); Text("All alerts").tag(2) }.frame(width: 230)
                Toggle("Glance mode (bigger text)", isOn: Binding(get: { model.bool("glance") }, set: { model.set("glance", $0) }))
                Picker("CPU", selection: Binding(get: { model.int("cpuMhz") }, set: { model.set("cpuMhz", $0) })) { Text("240 MHz").tag(240); Text("160 MHz (cooler, longer battery)").tag(160) }.frame(width: 280)
            }
            Text("Pins apply live; the mic re-inits on the next capture. Keep the encoder off GPIO 0/2/12/15 (strapping) and 34–39 are input-only (fine for A/B/SW, not for the toggle if you need pull-ups: the firmware uses internal pull-ups, so prefer 16/17/21/22/25/27/32/33).")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var hosts: [String: String] { (model.bridgeInfo["hosts"] as? [String: String]) ?? [:] }
    private var chosenHost: String? {
        switch hostChoice { case "lan": return hosts["lan"]; case "tailscale": return hosts["tailscale"]; case "custom": return customHost.isEmpty ? nil : customHost; default: return nil }
    }

    private var notificationsPanel: some View {
        let nc = (model.bridgeInfo["notifications"] as? [String: Any]) ?? [:]
        let accessible = nc["accessible"] as? Bool ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: accessible ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(accessible ? .green : .orange)
                Text(accessible ? "Relaying macOS notifications (Zoom, Slack, Mail, …) to the device inbox." : "Needs Full Disk Access for AITL Bridge to read the Notification Center store.")
                if !accessible {
                    Button("Grant Full Disk Access…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") { NSWorkspace.shared.open(url) }
                    }.buttonStyle(.borderedProminent).controlSize(.small)
                }
            }
            HStack {
                Button("Send test notification to device") {
                    Supervisor.post("/admin/notify_test", body: ["title": "AITL Bridge", "text": "Notification relay test from the Mac app"]) { _ in DispatchQueue.main.async { notifyResult = "sent" } }
                }
                Text(notifyResult).font(.caption).foregroundStyle(.secondary)
            }
            Text("Filter apps in ~/.config/aitl/config.toml under [notifications] (apps = allow-list of bundle ids, ignore = deny-list). Notifications land in the device inbox with a toast; Claude Code permission prompts stay modal.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Back buttons: BOOT tap = dictate, double-tap = next chat, hold = talk (device mic). The other button is the hardware RESET and cannot be remapped.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var displayPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Brightness"); Slider(value: Binding(get: { Double(model.int("brightness")) }, set: { _ in }), in: 10...255) { editing in if !editing { } }.disabled(true).frame(width: 220)
                Stepper("\(model.int("brightness"))", onIncrement: { model.set("brightness", min(255, model.int("brightness") + 25)) }, onDecrement: { model.set("brightness", max(10, model.int("brightness") - 25)) }).frame(width: 90) }
            Picker("Screen dims after", selection: Binding(get: { model.int("screenTimeout") }, set: { model.set("screenTimeout", $0) })) {
                Text("10 s").tag(10); Text("30 s").tag(30); Text("1 min").tag(60); Text("2 min").tag(120); Text("5 min").tag(300); Text("10 min").tag(600); Text("Never").tag(0)
            }.frame(width: 300)
            Picker("Rotation", selection: Binding(get: { model.int("rotation") }, set: { model.set("rotation", $0) })) {
                Text("Portrait").tag(0); Text("Landscape A").tag(1); Text("Portrait flipped").tag(2); Text("Landscape B (SD slot up)").tag(3)
            }.frame(width: 340)
            Toggle("Invert colors", isOn: Binding(get: { model.bool("invertColors") }, set: { model.set("invertColors", $0) }))
            Toggle("Swap red/blue", isOn: Binding(get: { model.bool("bgrOrder") }, set: { model.set("bgrOrder", $0) }))
        }
    }

    private var touchPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Long-press time", selection: Binding(get: { model.int("longPressMs") }, set: { model.set("longPressMs", $0) })) {
                Text("250 ms").tag(250); Text("400 ms").tag(400); Text("600 ms").tag(600); Text("900 ms").tag(900)
            }.frame(width: 260)
            Picker("Touch sensitivity", selection: Binding(get: { model.int("touchDebounce") }, set: { model.set("touchDebounce", $0) })) {
                Text("Instant").tag(1); Text("Normal").tag(2); Text("Firm").tag(3); Text("Deliberate").tag(4)
            }.frame(width: 260)
            Toggle("LED flash on tap", isOn: Binding(get: { model.bool("hapticLed") }, set: { model.set("hapticLed", $0) }))
            Text("Calibration itself runs on the device: Setup › Calibrate touch (or the setup wizard).").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var dictationPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Microphone", selection: Binding(get: { model.int("dictSource") }, set: { model.set("dictSource", $0) })) {
                Text("Host Mac (macOS dictation)").tag(0); Text("Device mic (I²S on the header)").tag(1)
            }.frame(width: 360)
            Picker("Device mic sends to", selection: Binding(get: { model.int("dictTarget") }, set: { model.set("dictTarget", $0) })) {
                Text("Ask the AI").tag(0); Text("Type into the Mac").tag(1)
            }.frame(width: 300)
            Stepper("Mic gain: \(model.int("micGain"))", onIncrement: { model.set("micGain", min(8, model.int("micGain") + 1)) }, onDecrement: { model.set("micGain", max(1, model.int("micGain") - 1)) }).frame(width: 200)
            Text("Host dictation presses Control twice when the frontmost app has no Start Dictation menu; set System Settings › Keyboard › Dictation › Shortcut to “Press Control key twice”.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var blePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Bluetooth keyboard (pairs with any computer or phone)", isOn: Binding(get: { model.bool("bleEnabled") }, set: { model.set("bleEnabled", $0) }))
            Toggle("Bluetooth link to this Mac (chat without a cable)", isOn: Binding(get: { model.bool("bleLink") }, set: { model.set("bleLink", $0) }))
            Picker("Keystrokes via", selection: Binding(get: { model.int("hidTarget") }, set: { model.set("hidTarget", $0) })) {
                Text("This Mac (bridge)").tag(0); Text("Bluetooth keyboard (whatever it is paired to)").tag(1)
            }.frame(width: 420)
            Picker("Bluetooth dictation key", selection: Binding(get: { model.int("dictShortcut") }, set: { model.set("dictShortcut", $0) })) {
                Text("Right ⌘ twice").tag(0); Text("Control twice").tag(1); Text("F5").tag(2); Text("⌘⌥D").tag(3)
            }.frame(width: 300)
            HStack(spacing: 12) {
                Text(model.int("bleBonds") < 0 ? "Bluetooth is off" : "Paired devices remembered: \(model.int("bleBonds"))").font(.callout)
                Button("Forget all pairings") {
                    let a = NSAlert(); a.messageText = "Forget all Bluetooth pairings?"; a.informativeText = "Your Mac and phone will need to pair with the AITL keyboard again."
                    a.addButton(withTitle: "Forget"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { model.bleForget { bleResult = $0 } }
                }.disabled(model.int("bleBonds") <= 0)
                Text(bleResult).font(.caption).foregroundStyle(.secondary)
            }
            Text(model.bool("wifiEnabled") ? "Bluetooth is parked while Wi-Fi is on (not enough RAM for both radios and the UI)." : "To pair a new phone or computer: open its Bluetooth settings and pick “AITL”. The device accepts one connection at a time; the last paired device reconnects first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var maintenancePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Log chats to microSD", isOn: Binding(get: { model.bool("sdLog") }, set: { model.set("sdLog", $0) }))
            HStack(spacing: 12) {
                Button("Restart device") { model.set("reboot", 1, note: "Device restarting") }
                Button("Install Claude Code hooks") { let out = supervisor.runCLI(["hooks", "install"]); model.lastMessage = String(out.prefix(80)) }
                Button("Open log") { NSWorkspace.shared.open(Supervisor.logURL) }
                Button("Edit bridge config") { NSWorkspace.shared.open(Supervisor.configURL) }
                Button("Factory reset…", role: .destructive) {
                    let a = NSAlert(); a.messageText = "Factory reset the device?"; a.informativeText = "Erases settings, Wi-Fi, pairing and calibration. The setup wizard runs on next boot."
                    a.addButton(withTitle: "Reset"); a.addButton(withTitle: "Cancel")
                    if a.runModal() == .alertFirstButtonReturn { model.set("factoryReset", 1, note: "Factory reset sent") }
                }
            }
        }
    }
}
