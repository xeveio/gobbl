import Foundation

/// Adds and removes Gobbl's hooks in Claude Code's settings.json, Codex's
/// hooks.json, and Grok's ~/.grok/hooks/gobbl.json (all use the same hook
/// format) without disturbing anything else in those files. Pure functions
/// over the file contents so they can be tested; the app does the I/O.
public enum AgentHookConfig {
    /// Every command Gobbl installs contains this, which is how we find our own entries.
    public static let marker = "gobbl-agent"

    /// Hook events Gobbl listens to. All run async (the agent never waits on
    /// Gobbl) except PermissionRequest, which exists to wait for an answer.
    public static let claudeEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
    /// Codex has the same lifecycle hooks, minus Notification.
    public static let codexEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "Stop", "SessionEnd"]
    /// Grok has Claude's events plus PostToolUse (thinking vs coding) and the
    /// interrupt/error stops. No PermissionRequest hook, so no notch approvals.
    public static let grokEvents = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse",
                                    "Notification", "Stop", "StopFailure", "StopCancelled", "SessionEnd"]

    public static func claudeCommand(helper: String) -> String {
        "/usr/bin/perl \"\(helper)\" claude"
    }

    public static func codexCommand(helper: String) -> String {
        "/usr/bin/perl \"\(helper)\" codex"
    }

    public static func grokCommand(helper: String) -> String {
        "/usr/bin/perl \"\(helper)\" grok"
    }

    public enum ConfigError: Error, Equatable {
        case notJSONObject
    }

    // MARK: Claude Code

    /// Returns settings.json contents with Gobbl's hooks installed (replacing any previous Gobbl entries).
    public static func installClaude(into data: Data?, helper: String, approvals: Bool, approvalTimeout: Int = 45) throws -> Data {
        try install(into: data, events: claudeEvents, command: claudeCommand(helper: helper),
                    approvals: approvals, approvalTimeout: approvalTimeout)
    }

    /// Returns settings.json contents with every Gobbl hook removed.
    public static func uninstallClaude(from data: Data?) throws -> Data {
        try uninstall(from: data)
    }

    public static func claudeStatus(_ data: Data?) -> (connected: Bool, approvals: Bool) {
        status(data, events: claudeEvents)
    }

    // MARK: Codex

    /// Returns ~/.codex/hooks.json contents with Gobbl's hooks installed. Codex reads
    /// these alongside its single `notify` command, so another tool's notify is untouched.
    public static func installCodex(into data: Data?, helper: String, approvals: Bool, approvalTimeout: Int = 45) throws -> Data {
        try install(into: data, events: codexEvents, command: codexCommand(helper: helper),
                    approvals: approvals, approvalTimeout: approvalTimeout)
    }

    public static func uninstallCodex(from data: Data?) throws -> Data {
        try uninstall(from: data)
    }

    public static func codexStatus(_ data: Data?) -> (connected: Bool, approvals: Bool) {
        status(data, events: codexEvents)
    }

    // MARK: Grok

    /// Returns ~/.grok/hooks/gobbl.json contents with Gobbl's hooks installed.
    /// Grok's Stop is a gate, so these run with a short timeout and no `async`
    /// flag (Grok may not honor it); gobbl-agent exits 0 with empty stdout.
    public static func installGrok(into data: Data?, helper: String) throws -> Data {
        try install(into: data, events: grokEvents, command: grokCommand(helper: helper),
                    approvals: false, async: false, timeout: 5)
    }

    public static func uninstallGrok(from data: Data?) throws -> Data {
        try uninstall(from: data)
    }

    public static func grokStatus(_ data: Data?) -> (connected: Bool, approvals: Bool) {
        status(data, events: grokEvents)
    }

    /// Older Gobbl versions connected Codex through a `notify` line in config.toml,
    /// which only reported finished turns. Hooks replace it.
    public static func hasLegacyCodexNotify(_ configToml: String) -> Bool {
        configToml.components(separatedBy: "\n").contains { isLegacyNotify($0) }
    }

    /// config.toml with Gobbl's old notify line removed; anyone else's notify stays.
    public static func removeLegacyCodexNotify(from configToml: String) -> String {
        configToml.components(separatedBy: "\n").filter { !isLegacyNotify($0) }.joined(separator: "\n")
    }

    private static func isLegacyNotify(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("notify") && line.contains(marker)
    }

    // MARK: Shared

    private static func install(into data: Data?, events: [String], command: String, approvals: Bool,
                                approvalTimeout: Int = 45, async: Bool = true, timeout: Int? = nil) throws -> Data {
        var root = try parse(data)
        var hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        for event in events {
            var groups = hooks[event] as? [[String: Any]] ?? []
            var handler: [String: Any] = ["type": "command", "command": command]
            if async { handler["async"] = true }
            if let timeout { handler["timeout"] = timeout }
            groups.append(["hooks": [handler]])
            hooks[event] = groups
        }
        if approvals {
            var groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
            groups.append(["hooks": [["type": "command", "command": command, "timeout": approvalTimeout]]])
            hooks["PermissionRequest"] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    private static func uninstall(from data: Data?) throws -> Data {
        var root = try parse(data)
        let hooks = strip(root["hooks"] as? [String: Any] ?? [:])
        if hooks.isEmpty { root["hooks"] = nil } else { root["hooks"] = hooks }
        return try serialize(root)
    }

    private static func status(_ data: Data?, events: [String]) -> (connected: Bool, approvals: Bool) {
        guard let root = try? parse(data), let hooks = root["hooks"] as? [String: Any] else { return (false, false) }
        func has(_ event: String) -> Bool {
            (hooks[event] as? [[String: Any]] ?? []).contains(where: isOurs)
        }
        return (events.contains(where: has), has("PermissionRequest"))
    }

    private static func isOurs(_ group: [String: Any]) -> Bool {
        (group["hooks"] as? [[String: Any]] ?? []).contains { ($0["command"] as? String)?.contains(marker) ?? false }
    }

    /// Removes Gobbl's hook groups, and events left empty by that.
    private static func strip(_ hooks: [String: Any]) -> [String: Any] {
        var out = hooks
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            let kept = groups.filter { !isOurs($0) }
            out[event] = kept.isEmpty ? nil : kept
        }
        return out
    }

    private static func parse(_ data: Data?) throws -> [String: Any] {
        guard let data, !data.isEmpty,
              !(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) else { return [:] }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ConfigError.notJSONObject }
        return root
    }

    private static func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        data.append(0x0A)
        return data
    }

}
