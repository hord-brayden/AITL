import Foundation
import Combine

/// Live device settings fetched through the bridge's loopback admin API, plus setters.
@MainActor
final class DeviceModel: ObservableObject {
    struct ModelInfo: Identifiable { let id: String; let label: String; let provider: String; let ok: Bool }
    @Published var settings: [String: Any] = [:]
    @Published var models: [ModelInfo] = []
    @Published var bridgeInfo: [String: Any] = [:]
    @Published var error: String = ""
    @Published var busy = false
    @Published var lastMessage = ""
    struct Network: Identifiable { var id: String { ssid }; let ssid: String; let prio: Int; let current: Bool }
    struct Seen: Identifiable { var id: String { ssid }; let ssid: String; let rssi: Int }
    @Published var networks: [Network] = []
    @Published var wifiCurrent = ""
    @Published var scan: [Seen] = []
    @Published var scanning = false
    @Published var diag: [String: Any] = [:]
    @Published var ntfy: [String: Any] = [:]

    var deviceId: String { settings["id"] as? String ?? "" }
    func bool(_ k: String) -> Bool { settings[k] as? Bool ?? false }
    func int(_ k: String) -> Int { (settings[k] as? Int) ?? Int((settings[k] as? Double) ?? 0) }
    func str(_ k: String) -> String { settings[k] as? String ?? "" }

    func refresh() {
        Supervisor.get("/admin/get") { data in
            DispatchQueue.main.async {
                guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { self.error = "bridge not reachable"; return }
                if obj["ok"] as? Bool == true {
                    self.error = ""
                    let devs = obj["devices"] as? [String: [String: Any]] ?? [:]
                    self.settings = devs.values.first ?? [:]
                    self.models = (obj["models"] as? [[String: Any]] ?? []).compactMap { m in
                        guard let id = m["id"] as? String else { return nil }
                        return ModelInfo(id: id, label: m["label"] as? String ?? id, provider: m["provider"] as? String ?? "", ok: m["ok"] as? Bool ?? false)
                    }
                    self.bridgeInfo = obj["bridge"] as? [String: Any] ?? [:]
                    self.ntfy = (self.bridgeInfo["ntfy"] as? [String: Any]) ?? [:]
                    self.diag = (obj["diag"] as? [String: [String: Any]] ?? [:]).values.first ?? [:]
                    if let nets = self.settings["wifiNetworks"] as? [[String: Any]] { self.applyNetworks(nets, current: self.settings["wifiSsid"] as? String ?? "") }
                } else {
                    self.error = obj["error"] as? String ?? "no device"
                    if self.error.contains("no device") { self.settings = [:] }
                }
            }
        }
    }

    func set(_ key: String, _ value: Any, note: String? = nil) {
        busy = true
        Supervisor.post("/admin/set", body: ["key": key, "value": value]) { data in
            DispatchQueue.main.async {
                self.busy = false
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                if obj["ok"] as? Bool == true { self.lastMessage = note ?? "Applied \(key)"; self.settings[key] = value }
                else { self.error = (obj["error"] as? String) ?? "failed to apply \(key)" }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.refresh() }
            }
        }
    }

    private func applyNetworks(_ nets: [[String: Any]], current: String) {
        networks = nets.compactMap { n in
            guard let ssid = n["ssid"] as? String else { return nil }
            return Network(ssid: ssid, prio: (n["prio"] as? Int) ?? 0, current: (n["current"] as? Bool) ?? (ssid == current))
        }
        wifiCurrent = current
    }

    /// Network table ops (`wifi_list|wifi_add|wifi_remove|wifi_use`). Adding goes over USB only; the password never touches the air or disk here.
    func wifi(_ op: String, ssid: String = "", password: String = "", prio: Int = 0, completion: ((String) -> Void)? = nil) {
        busy = true
        var body: [String: Any] = ["ssid": ssid, "prio": prio]
        if op == "wifi_add" { body["password"] = password }
        Supervisor.post("/admin/\(op)", body: body) { data in
            DispatchQueue.main.async {
                self.busy = false
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                if obj["ok"] as? Bool == true {
                    self.applyNetworks(obj["list"] as? [[String: Any]] ?? [], current: obj["current"] as? String ?? "")
                    completion?(op == "wifi_add" ? "Saved \(ssid). The device joins it next time it connects (or now, if it is the strongest)." : "")
                } else { completion?("Failed: \(obj["error"] as? String ?? "unknown")") }
            }
        }
    }

    func wifiScan() {
        scanning = true
        Supervisor.post("/admin/wifi_scan", body: [:]) { data in
            DispatchQueue.main.async {
                self.scanning = false
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                self.scan = (obj["list"] as? [[String: Any]] ?? []).compactMap { n in
                    guard let ssid = n["ssid"] as? String else { return nil }
                    return Seen(ssid: ssid, rssi: (n["rssi"] as? Int) ?? -100)
                }.sorted { $0.rssi > $1.rssi }
                if obj["ok"] as? Bool != true { self.error = obj["error"] as? String ?? "scan failed" }
            }
        }
    }

    func bleForget(completion: @escaping (String) -> Void) {
        Supervisor.post("/admin/ble_forget", body: [:]) { data in
            DispatchQueue.main.async {
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                completion(obj["ok"] as? Bool == true ? "All Bluetooth pairings forgotten. Re-pair from the other device." : "Failed: \(obj["error"] as? String ?? "unknown")")
                self.refresh()
            }
        }
    }

    /// Bridge config (config.toml) and Keychain secrets, through the loopback admin API.
    func configSet(_ section: String, _ key: String, _ value: Any, completion: ((Bool) -> Void)? = nil) {
        Supervisor.post("/admin/config_set", body: ["section": section, "key": key, "value": value]) { data in
            DispatchQueue.main.async {
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let ok = obj["ok"] as? Bool == true
                if !ok { self.error = obj["error"] as? String ?? "config change failed" }
                completion?(ok)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
            }
        }
    }
    func keySet(_ provider: String, _ value: String, completion: ((Bool) -> Void)? = nil) {
        Supervisor.post("/admin/key_set", body: ["provider": provider, "value": value]) { data in
            DispatchQueue.main.async {
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                completion?(obj["ok"] as? Bool == true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refresh() }
            }
        }
    }
    func ntfyTest(completion: @escaping (String) -> Void) {
        Supervisor.post("/admin/ntfy_test", body: [:]) { data in
            DispatchQueue.main.async {
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                completion(obj["ok"] as? Bool == true ? "Sent. Check your phone." : "Failed: \(obj["error"] as? String ?? "unknown")")
            }
        }
    }

    func provision(ssid: String?, password: String?, bridge: Bool, host: String? = nil, completion: @escaping (String) -> Void) {
        var body: [String: Any] = ["bridge": bridge]
        if let host, !host.isEmpty { body["host"] = host }
        if let ssid, !ssid.isEmpty { body["ssid"] = ssid; body["password"] = password ?? "" }
        busy = true
        Supervisor.post("/admin/provision", body: body) { data in
            DispatchQueue.main.async {
                self.busy = false
                let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                if obj["ok"] as? Bool == true {
                    let sent = (obj["sent"] as? [String] ?? []).joined(separator: ", ")
                    completion("Sent over USB: \(sent). The device restarts onto Wi-Fi.")
                } else { completion("Failed: \(obj["error"] as? String ?? "unknown")") }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { self.refresh() }
            }
        }
    }
}
