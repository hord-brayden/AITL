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

    func provision(ssid: String?, password: String?, bridge: Bool, completion: @escaping (String) -> Void) {
        var body: [String: Any] = ["bridge": bridge]
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
