import Foundation

/// One message from an AI coding agent, decoded from a Claude Code, Codex or
/// Grok hook payload (stdin JSON), or a legacy Codex `notify` payload (argv JSON).
public struct AgentEvent: Equatable, Sendable {
    public enum Source: String, Sendable, CaseIterable {
        case claude, codex, grok

        public var displayName: String {
            switch self {
            case .claude: "Claude Code"
            case .codex: "Codex"
            case .grok: "Grok"
            }
        }
    }

    public enum Kind: Equatable, Sendable {
        case sessionStart
        case promptSubmitted
        case toolUse(String)
        /// A tool returned; the model is reasoning about what's next.
        case toolFinished
        /// Claude wants to use a tool; with approvals on, Gobbl can answer.
        case permissionRequest(tool: String, detail: String?)
        /// A "needs you" notification: a permission prompt or a question.
        case needsInput(String)
        case turnDone(String?)
        /// Turn ended without completing (interrupt, API error). No cheer.
        case turnAborted
        case sessionEnd
    }

    public var source: Source
    public var sessionID: String
    public var cwd: String?
    public var kind: Kind

    public init(source: Source, sessionID: String, cwd: String?, kind: Kind) {
        self.source = source
        self.sessionID = sessionID
        self.cwd = cwd
        self.kind = kind
    }

    /// Returns nil for events Gob doesn't care about.
    public static func parse(source: Source, json: Data) -> AgentEvent? {
        guard let o = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        // Claude Code / Codex use snake_case; Grok uses camelCase and also sends
        // Claude's `hook_event_name` alias. Accept both.
        func str(_ keys: String...) -> String? {
            for key in keys {
                if let v = o[key] as? String, !v.isEmpty { return v }
            }
            return nil
        }
        let cwd = str("cwd")
        // Grok subagents have their own sessionId and often no parent-style Stop.
        if str("subagentType", "subagent_type") != nil { return nil }

        // Lifecycle hooks: Claude Code, Codex, and Grok (same events, mixed key styles).
        if let event = hookEventName(str("hook_event_name") ?? str("hookEventName")) {
            let kind: Kind
            switch event {
            case "SessionStart": kind = .sessionStart
            case "UserPromptSubmit": kind = .promptSubmitted
            case "PreToolUse": kind = .toolUse(str("tool_name", "toolName") ?? "tool")
            case "PostToolUse": kind = .toolFinished
            case "PermissionRequest":
                kind = .permissionRequest(tool: str("tool_name", "toolName") ?? "a tool",
                                          detail: Self.detail(o["tool_input"] ?? o["toolInput"]))
            case "Notification":
                switch str("notification_type", "notificationType") {
                case "permission_prompt": kind = .needsInput("Needs your permission")
                case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input": kind = .needsInput("Has a question")
                default: return nil // idle_prompt fires after a finished turn: nothing new to say
                }
            case "Stop":
                // Grok also fires Stop on session teardown; that isn't a finished task.
                // Only Grok: Claude Code and Codex don't document a `reason`, so their Stop always cheers.
                if resolvedSource(claimed: source, json: o) == .grok, let reason = str("reason"), reason != "end_turn" {
                    kind = .sessionEnd
                } else {
                    kind = .turnDone(str("last_assistant_message", "lastAssistantMessage"))
                }
            case "StopFailure", "StopCancelled": kind = .turnAborted
            case "SessionEnd": kind = .sessionEnd
            default: return nil
            }
            return AgentEvent(source: resolvedSource(claimed: source, json: o),
                              sessionID: str("session_id", "sessionId") ?? source.rawValue, cwd: cwd, kind: kind)
        }
        // Legacy Codex notify: {"type":"agent-turn-complete","turn-id":…,"last-assistant-message":…,"cwd"?}
        guard source == .codex, str("type") == "agent-turn-complete" else { return nil }
        return AgentEvent(source: .codex, sessionID: "codex:\(cwd ?? "default")", cwd: cwd,
                          kind: .turnDone(str("last-assistant-message")))
    }

    /// Grok payloads include camelCase `hookEventName`; Claude Code and Codex do not.
    static func resolvedSource(claimed: Source, json: [String: Any]) -> Source {
        if claimed == .grok { return .grok }
        if json["hookEventName"] != nil { return .grok }
        return claimed
    }

    /// Claude sends PascalCase (`PreToolUse`). Grok's `hookEventName` is snake_case (`pre_tool_use`).
    static func hookEventName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.contains("_") {
            return raw.split(separator: "_").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
        return raw
    }

    /// The interesting part of a tool call: a command, a path, a URL.
    static func detail(_ input: Any?) -> String? {
        guard let input = input as? [String: Any] else { return nil }
        for key in ["command", "file_path", "path", "url", "pattern", "description", "prompt"] {
            if let value = input[key] as? String, !value.isEmpty { return String(value.prefix(300)) }
        }
        return nil
    }
}

public struct AgentSession: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case working(tool: String?)
        case waiting(String)
        case done(String?)
    }

    public var id: String
    public var source: AgentEvent.Source
    public var cwd: String?
    public var state: State
    public var updated: Date
    public var started: Date
    /// Bundle ID of the app the prompt was typed in (the terminal or editor), to jump back to.
    public var hostApp: String?

    public var project: String {
        guard let cwd else { return source.displayName }
        return (cwd as NSString).lastPathComponent
    }

    public var isWorking: Bool {
        if case .working = state { return true }
        return false
    }
}

/// All live agent sessions, newest activity first.
public struct AgentTracker: Equatable, Sendable {
    public enum Effect: Equatable, Sendable {
        case none
        case startedWorking
        case needsYou(String)
        case done(String?)
    }

    public static let staleWorking: TimeInterval = 10 * 60
    public static let forgetDone: TimeInterval = 20 * 60
    /// A second "done" this soon after the first is the same turn delivered twice.
    public static let duplicateDone: TimeInterval = 5

    public private(set) var sessions: [AgentSession] = []

    public init() {}

    public var anyWorking: Bool { sessions.contains(where: \.isWorking) }

    /// Coding if any session is running a tool, thinking if any is reasoning.
    public var activity: AgentActivity {
        var thinking = false
        for s in sessions {
            guard case .working(let tool) = s.state else { continue }
            if tool != nil { return .coding }
            thinking = true
        }
        return thinking ? .thinking : .idle
    }

    @discardableResult
    public mutating func apply(_ e: AgentEvent, now: Date = Date(), hostApp: String? = nil) -> Effect {
        if e.kind == .sessionEnd {
            sessions.removeAll { $0.id == e.sessionID }
            return .none
        }
        var s = sessions.first { $0.id == e.sessionID }
            ?? AgentSession(id: e.sessionID, source: e.source, cwd: e.cwd, state: .idle, updated: now, started: now)
        sessions.removeAll { $0.id == e.sessionID }
        let wasWorking = s.isWorking
        let previousUpdate = s.updated
        s.updated = now
        if e.source == .grok { s.source = .grok }
        if let cwd = e.cwd { s.cwd = cwd }
        var effect = Effect.none
        switch e.kind {
        case .sessionStart:
            s.state = .idle
        case .promptSubmitted:
            s.state = .working(tool: nil)
            if let hostApp { s.hostApp = hostApp }
            effect = wasWorking ? .none : .startedWorking
        case .toolUse(let tool):
            s.state = .working(tool: tool)
            effect = wasWorking ? .none : .startedWorking
        case .toolFinished:
            s.state = .working(tool: nil)
        case .permissionRequest(let tool, _):
            s.state = .waiting("Wants to use \(tool)")
            effect = .needsYou("Wants to use \(tool)")
        case .needsInput(let message):
            // A permission request already said this more precisely.
            if case .waiting = s.state { break }
            s.state = .waiting(message)
            effect = .needsYou(message)
        case .turnDone(let message):
            // The same turn reported twice (Grok also runs Claude Code's hooks): cheer once. A later
            // turn still cheers, even from legacy Codex notify, which sends nothing but turnDone.
            if case .done = s.state, now.timeIntervalSince(previousUpdate) < Self.duplicateDone { break }
            s.state = .done(message)
            effect = .done(message)
        case .turnAborted:
            s.state = .idle
        case .sessionEnd:
            break
        }
        sessions.insert(s, at: 0)
        return effect
    }

    /// After a decision from the notch, the agent carries on.
    public mutating func resolveWaiting(_ sessionID: String, now: Date = Date()) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }), case .waiting = sessions[i].state else { return }
        sessions[i].state = .working(tool: nil)
        sessions[i].updated = now
    }

    /// Working sessions with no news for 10 minutes go idle (a crash or a
    /// closed terminal sends nothing); finished ones are forgotten after 20.
    public mutating func expire(now: Date = Date()) {
        for i in sessions.indices where sessions[i].isWorking && now.timeIntervalSince(sessions[i].updated) > Self.staleWorking {
            sessions[i].state = .idle
        }
        sessions.removeAll { s in
            switch s.state {
            case .done, .idle: return now.timeIntervalSince(s.updated) > Self.forgetDone
            default: return false
            }
        }
    }
}
