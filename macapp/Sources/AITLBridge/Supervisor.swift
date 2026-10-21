import Foundation

/// Runs the Python bridge as a child of this app (so macOS attributes Bluetooth and Accessibility use to
/// "AITL Bridge"), restarts it if it dies, and reads its status over the loopback admin endpoint.
final class Supervisor {
    struct Device: Decodable { let id: String; let transport: String; let model: String; let fw: String }
    struct Status { var running = false; var devices: [Device] = []; var macControl: Bool? = nil; var macError = "" }

    static let configDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/aitl")
    static let venvPython = configDir.appendingPathComponent("venv/bin/python3")
    static let logURL = configDir.appendingPathComponent("bridge.log")
    static let configURL = configDir.appendingPathComponent("config.toml")
    static let adminBase = "http://127.0.0.1:7778"

    var status = Status()
    private var process: Process?
    private var wantRunning = false
    private var restartDelay: TimeInterval = 2
    private var shellEnv: [String: String] = [:]
    var onChange: (() -> Void)?

    var runtimeInstalled: Bool { FileManager.default.isExecutableFile(atPath: Self.venvPython.path) }

    init() {
        shellEnv = Self.importShellEnvironment()
        unloadLegacyLaunchAgent()
    }

    // MARK: lifecycle
    func start() {
        wantRunning = true
        guard process == nil else { return }
        guard runtimeInstalled else { status.running = false; onChange?(); return }
        let p = Process()
        p.executableURL = Self.venvPython
        p.arguments = ["-m", "aitl_bridge.cli", "-v", "serve"]
        var env = ProcessInfo.processInfo.environment
        for (k, v) in shellEnv { env[k] = v }
        env["AITL_IN_BUNDLE"] = "1"
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        p.environment = env
        if let log = try? FileHandle(forWritingTo: Self.logURL) { log.seekToEndOfFile(); p.standardOutput = log; p.standardError = log }
        else { FileManager.default.createFile(atPath: Self.logURL.path, contents: nil); if let log = try? FileHandle(forWritingTo: Self.logURL) { p.standardOutput = log; p.standardError = log } }
        p.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                self.process = nil
                self.status.running = false
                self.status.devices = []
                self.onChange?()
                if self.wantRunning {
                    let delay = self.restartDelay
                    self.restartDelay = min(30, self.restartDelay * 2)
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { self.start() }
                }
            }
        }
        do {
            try p.run()
            process = p
            status.running = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.restartDelay = 2 }
        } catch {
            status.running = false
            status.macError = "launch failed: \(error.localizedDescription)"
        }
        onChange?()
    }

    func stop() {
        wantRunning = false
        process?.terminate()
        process = nil
        status.running = false
        status.devices = []
        onChange?()
    }

    func restart() { stop(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.start() } }

    // MARK: status
    func refresh() {
        guard status.running else { onChange?(); return }
        Self.get("/admin/status") { [weak self] data in
            guard let self else { return }
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let devs = obj["devices"] as? [[String: Any]] {
                self.status.devices = devs.compactMap { d in
                    guard let id = d["id"] as? String else { return nil }
                    return Device(id: id, transport: d["transport"] as? String ?? "?", model: d["model"] as? String ?? "", fw: d["fw"] as? String ?? "")
                }
            }
            Self.get("/admin/probe") { data in
                if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    self.status.macControl = obj["keystrokes"] as? Bool
                    self.status.macError = obj["error"] as? String ?? ""
                }
                DispatchQueue.main.async { self.onChange?() }
            }
        }
    }

    func openPairingWindow(completion: @escaping (String?) -> Void) {
        Self.post("/admin/pair_open", body: ["seconds": 180]) { data in
            let fp = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["fingerprint"] as? String
            DispatchQueue.main.async { completion(fp) }
        }
    }

    /// Runs an `aitl` subcommand with the private runtime (hooks install, install-app, keys list…).
    @discardableResult
    func runCLI(_ args: [String]) -> String {
        let p = Process()
        p.executableURL = Self.venvPython
        p.arguments = ["-m", "aitl_bridge.cli"] + args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in shellEnv { env[k] = v }
        env["PYTHONNOUSERSITE"] = "1"
        p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        do { try p.run() } catch { return "failed: \(error.localizedDescription)" }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return out
    }

    // MARK: helpers
    static func get(_ path: String, _ done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: URL(string: adminBase + path)!); req.timeoutInterval = 4
        URLSession.shared.dataTask(with: req) { data, _, _ in done(data) }.resume()
    }
    static func post(_ path: String, body: [String: Any], _ done: @escaping (Data?) -> Void) {
        var req = URLRequest(url: URL(string: adminBase + path)!); req.httpMethod = "POST"; req.timeoutInterval = 6
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        URLSession.shared.dataTask(with: req) { data, _, _ in done(data) }.resume()
    }

    /// Apps launched from Finder/login have no shell environment; import API keys and PATH from the login shell.
    private static func importShellEnvironment() -> [String: String] {
        let wanted: Set<String> = ["GEMINI_API_KEY", "GOOGLE_API_KEY", "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "MUSE_API_KEY", "AITL_HOME", "PATH"]
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-lc", "env"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        var result: [String: String] = [:]
        do { try p.run() } catch { return result }
        let deadline = Date().addingTimeInterval(5)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        for line in out.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<eq]); let v = String(line[line.index(after: eq)...])
            if wanted.contains(k) { result[k] = v }
        }
        return result
    }

    /// The CLI's LaunchAgent (`aitl autostart on`) would run a second bridge; this app supervises its own.
    private func unloadLegacyLaunchAgent() {
        let label = "com.caeruli-obscuri.aitl.bridge"
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["bootout", "gui/\(getuid())/\(label)"]; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(label).plist")
        try? FileManager.default.removeItem(at: plist)
        // and any bridge the CLI started directly
        let k = Process(); k.executableURL = URL(fileURLWithPath: "/usr/bin/pkill"); k.arguments = ["-f", "aitl_bridge.cli.* serve"]
        k.standardOutput = FileHandle.nullDevice; k.standardError = FileHandle.nullDevice
        try? k.run(); k.waitUntilExit()
    }
}
