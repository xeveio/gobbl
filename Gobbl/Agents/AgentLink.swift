import AppKit
import GobblCore

/// Connects Claude Code, Codex and Grok to Gobbl, only when the user asks:
/// installs the `gobbl-agent` helper and adds (or removes) Gobbl's hooks in
/// ~/.claude/settings.json, ~/.codex/hooks.json and ~/.grok/hooks/gobbl.json.
/// Each file is backed up to `<file>.gobbl-backup` before it is changed;
/// symlinked dotfiles are followed.
@MainActor
enum AgentLink {
    static let helperURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gobbl/bin/gobbl-agent")

    private static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
    static var claudeSettings: URL { home.appendingPathComponent(".claude/settings.json") }
    static var codexConfig: URL { home.appendingPathComponent(".codex/config.toml") }
    static var codexHooks: URL { home.appendingPathComponent(".codex/hooks.json") }
    static var grokHooks: URL { home.appendingPathComponent(".grok/hooks/gobbl.json") }

    static var claudeInstalled: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude").path) }
    static var codexInstalled: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".codex").path) }
    static var grokInstalled: Bool { FileManager.default.fileExists(atPath: home.appendingPathComponent(".grok").path) }

    // MARK: Claude Code

    static func claudeStatus() -> (connected: Bool, approvals: Bool) {
        AgentHookConfig.claudeStatus(try? Data(contentsOf: claudeSettings))
    }

    static func connectClaude(approvals: Bool) throws {
        try installHelper()
        let url = claudeSettings.resolvingSymlinksInPath()
        let old = try? Data(contentsOf: url)
        let new = try AgentHookConfig.installClaude(into: old, helper: helperURL.path, approvals: approvals)
        try write(new, to: url, backup: old)
        UserDefaults.standard.set(approvals, forKey: "agentApprovals")
    }

    static func disconnectClaude() throws {
        let url = claudeSettings.resolvingSymlinksInPath()
        guard let old = try? Data(contentsOf: url) else { return }
        try write(try AgentHookConfig.uninstallClaude(from: old), to: url, backup: old)
        UserDefaults.standard.set(false, forKey: "agentApprovals")
    }

    // MARK: Codex

    /// Connected through hooks.json, or through the notify line older versions added.
    static func codexConnected() -> Bool {
        AgentHookConfig.codexStatus(try? Data(contentsOf: codexHooks)).connected
            || AgentHookConfig.hasLegacyCodexNotify((try? String(contentsOf: codexConfig, encoding: .utf8)) ?? "")
    }

    /// Codex's lifecycle hooks, like Claude Code's: Gob sees prompts and tool use as they
    /// happen, not just finished turns. The PermissionRequest hook is always installed;
    /// with approvals off, AgentHub answers nothing and Codex asks as usual.
    static func connectCodex() throws {
        try installHelper()
        let url = codexHooks.resolvingSymlinksInPath()
        let old = try? Data(contentsOf: url)
        try write(try AgentHookConfig.installCodex(into: old, helper: helperURL.path, approvals: true), to: url, backup: old)
        try removeLegacyCodexNotify()
    }

    static func disconnectCodex() throws {
        let url = codexHooks.resolvingSymlinksInPath()
        if let old = try? Data(contentsOf: url) {
            try write(try AgentHookConfig.uninstallCodex(from: old), to: url, backup: old)
        }
        try removeLegacyCodexNotify()
    }

    /// Drops the notify line older Gobbl versions put in config.toml; anyone else's stays.
    private static func removeLegacyCodexNotify() throws {
        let url = codexConfig.resolvingSymlinksInPath()
        guard let old = try? String(contentsOf: url, encoding: .utf8), AgentHookConfig.hasLegacyCodexNotify(old) else { return }
        try write(Data(AgentHookConfig.removeLegacyCodexNotify(from: old).utf8), to: url, backup: Data(old.utf8))
    }

    // MARK: Grok

    static func grokConnected() -> Bool {
        AgentHookConfig.grokStatus(try? Data(contentsOf: grokHooks)).connected
    }

    /// Grok's lifecycle hooks live in their own file so we never rewrite
    /// ~/.grok/config.toml or anyone else's hooks in ~/.grok/hooks/.
    static func connectGrok() throws {
        try installHelper()
        let url = grokHooks.resolvingSymlinksInPath()
        let old = try? Data(contentsOf: url)
        try write(try AgentHookConfig.installGrok(into: old, helper: helperURL.path), to: url, backup: old)
    }

    static func disconnectGrok() throws {
        let url = grokHooks.resolvingSymlinksInPath()
        guard let old = try? Data(contentsOf: url) else { return }
        try write(try AgentHookConfig.uninstallGrok(from: old), to: url, backup: old)
    }

    // MARK: Test

    /// Sends a fake "task done" through the real helper and socket, one per connected agent.
    static func sendTest() {
        do { try installHelper() } catch { return }
        if claudeStatus().connected {
            sendHook(source: "claude",
                     json: #"{"hook_event_name":"Stop","session_id":"test-claude","cwd":"/Gobbl test","last_assistant_message":"Hello from Gobbl"}"#)
        }
        if codexConnected() {
            // Legacy notify still parses; also works as a socket smoke test.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
            p.arguments = [helperURL.path, "codex",
                           #"{"type":"agent-turn-complete","turn-id":"test","last-assistant-message":"Hello from Gobbl","cwd":"/Gobbl test"}"#]
            try? p.run()
        }
        if grokConnected() {
            sendHook(source: "grok",
                     json: #"{"hookEventName":"stop","hook_event_name":"Stop","sessionId":"test-grok","cwd":"/Gobbl test","reason":"end_turn","lastAssistantMessage":"Hello from Gobbl"}"#)
        }
    }

    /// Lifecycle hooks (Claude Code, Codex, Grok) send JSON on stdin.
    private static func sendHook(source: String, json: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [helperURL.path, source]
        let pipe = Pipe()
        p.standardInput = pipe
        try? p.run()
        try? pipe.fileHandleForWriting.write(contentsOf: Data(json.utf8))
        try? pipe.fileHandleForWriting.close()
    }

    // MARK: Files

    /// Copies the bundled helper to a stable path (the app bundle may move).
    static func installHelper() throws {
        guard let source = Bundle.main.url(forResource: "gobbl-agent", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: helperURL.path) { try fm.removeItem(at: helperURL) }
        try fm.copyItem(at: source, to: helperURL)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
    }

    private static func write(_ data: Data, to url: URL, backup: Data?) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep the first backup: the file as it was before Gobbl ever changed it.
        let backupURL = url.appendingPathExtension("gobbl-backup")
        if let backup, !FileManager.default.fileExists(atPath: backupURL.path) { try backup.write(to: backupURL) }
        try data.write(to: url, options: .atomic)
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case AgentHookConfig.ConfigError.notJSONObject:
            return "The agent's hooks file isn't a JSON object, so Gobbl left it alone."
        default:
            return error.localizedDescription
        }
    }
}
