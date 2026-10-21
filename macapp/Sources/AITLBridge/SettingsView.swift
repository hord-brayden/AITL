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
                        section("Wi-Fi") { wifiPanel }
                        section("Display") { displayPanel }
                        section("Touch") { touchPanel }
                        section("Dictation") { dictationPanel }
                        section("Bluetooth & keystrokes") { blePanel }
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
            }
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
                    model.provision(ssid: ssid, password: password, bridge: true) { provisionResult = $0; password = "" }
                }.disabled(ssid.isEmpty || model.busy)
            }
            HStack {
                Button("Re-pair bridge only (new address / token)") { model.provision(ssid: nil, password: nil, bridge: true) { provisionResult = $0 } }.disabled(model.busy)
                Text("Current: \(model.str("wifiSsid").isEmpty ? "none" : model.str("wifiSsid"))  →  \(model.str("bridgeHost")):\(model.int("bridgePort"))  (\(model.int("wifiMode") == 1 ? "TLS" : "signed frames"))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !provisionResult.isEmpty { Text(provisionResult).font(.caption) }
            Text("The device must be on the same network as this Mac. Provisioning only works over the USB cable (possession is the credential). Frames on Wi-Fi are HMAC-signed with a per-session nonce; the password and token never travel over the air.")
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
            Text(model.bool("wifiEnabled") ? "Bluetooth is parked while Wi-Fi is on (not enough RAM for both radios and the UI)." : "Turn Bluetooth link off if you want to pair the keyboard with a phone; the device has one Bluetooth connection.")
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
