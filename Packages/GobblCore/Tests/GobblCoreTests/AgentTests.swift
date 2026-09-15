import Foundation
import Testing
@testable import GobblCore

@Suite struct AgentEventTests {
    private func claude(_ json: String) -> AgentEvent? { AgentEvent.parse(source: .claude, json: Data(json.utf8)) }

    @Test func parsesClaudeLifecycle() {
        #expect(claude(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/src/gobbl"}"#)?.kind == .promptSubmitted)
        #expect(claude(#"{"hook_event_name":"PreToolUse","session_id":"s1","tool_name":"Bash"}"#)?.kind == .toolUse("Bash"))
        #expect(claude(#"{"hook_event_name":"PostToolUse","session_id":"s1","tool_name":"Bash"}"#)?.kind == .toolFinished)
        #expect(claude(#"{"hook_event_name":"Stop","session_id":"s1","last_assistant_message":"All done"}"#)?.kind == .turnDone("All done"))
        #expect(claude(#"{"hook_event_name":"SessionEnd","session_id":"s1"}"#)?.kind == .sessionEnd)
        #expect(claude(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1","cwd":"/src/gobbl"}"#)?.cwd == "/src/gobbl")
    }

    @Test func parsesPermissionRequestDetail() {
        let e = claude(#"{"hook_event_name":"PermissionRequest","session_id":"s1","tool_name":"Bash","tool_input":{"command":"rm -rf build"}}"#)
        #expect(e?.kind == .permissionRequest(tool: "Bash", detail: "rm -rf build"))
    }

    @Test func notificationsThatNeedYou() {
        #expect(claude(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"permission_prompt"}"#)?.kind
                == .needsInput("Needs your permission"))
        #expect(claude(#"{"hook_event_name":"Notification","session_id":"s","notification_type":"idle_prompt"}"#) == nil)
    }

    @Test func parsesCodexNotify() {
        let e = AgentEvent.parse(source: .codex, json: Data(#"{"type":"agent-turn-complete","turn-id":"t","last-assistant-message":"Tests pass","cwd":"/src/x"}"#.utf8))
        #expect(e?.kind == .turnDone("Tests pass"))
        #expect(e?.sessionID == "codex:/src/x")
        #expect(AgentEvent.parse(source: .codex, json: Data(#"{"type":"something-else"}"#.utf8)) == nil)
    }

    @Test func parsesCodexHooks() {
        func codex(_ json: String) -> AgentEvent? { AgentEvent.parse(source: .codex, json: Data(json.utf8)) }
        let prompt = codex(#"{"hook_event_name":"UserPromptSubmit","session_id":"019d","turn_id":"t1","cwd":"/src/api","model":"gpt-5"}"#)
        #expect(prompt?.kind == .promptSubmitted)
        #expect(prompt?.source == .codex)
        #expect(prompt?.sessionID == "019d")
        #expect(prompt?.cwd == "/src/api")
        #expect(codex(#"{"hook_event_name":"PreToolUse","session_id":"019d","tool_name":"shell"}"#)?.kind == .toolUse("shell"))
        #expect(codex(#"{"hook_event_name":"PermissionRequest","session_id":"019d","tool_name":"shell","tool_input":{"command":"npm test"}}"#)?.kind
                == .permissionRequest(tool: "shell", detail: "npm test"))
        #expect(codex(#"{"hook_event_name":"Stop","session_id":"019d"}"#)?.kind == .turnDone(nil))
        #expect(codex(#"{"hook_event_name":"PreCompact","session_id":"019d"}"#) == nil)
    }

    @Test func ignoresGarbage() {
        #expect(claude("nope") == nil)
        #expect(claude(#"{"hook_event_name":"PreCompact","session_id":"s"}"#) == nil)
    }

    @Test func parsesGrokHooks() {
        func grok(_ json: String) -> AgentEvent? { AgentEvent.parse(source: .grok, json: Data(json.utf8)) }
        let prompt = grok(#"{"hookEventName":"user_prompt_submit","hook_event_name":"UserPromptSubmit","sessionId":"01a0","cwd":"/src/app"}"#)
        #expect(prompt?.kind == .promptSubmitted)
        #expect(prompt?.source == .grok)
        #expect(prompt?.sessionID == "01a0")
        #expect(prompt?.cwd == "/src/app")
        #expect(grok(#"{"hook_event_name":"PreToolUse","sessionId":"01a0","toolName":"run_terminal_command","toolInput":{"command":"npm test"}}"#)?.kind
                == .toolUse("run_terminal_command"))
        #expect(grok(#"{"hookEventName":"post_tool_use","sessionId":"01a0","toolName":"read_file"}"#)?.kind == .toolFinished)
        #expect(grok(#"{"hook_event_name":"Stop","sessionId":"01a0","reason":"end_turn","lastAssistantMessage":"All done"}"#)?.kind
                == .turnDone("All done"))
        #expect(grok(#"{"hook_event_name":"Stop","sessionId":"01a0","reason":"shutdown"}"#)?.kind == .sessionEnd)
        #expect(grok(#"{"hook_event_name":"StopCancelled","sessionId":"01a0","reason":"user_interrupt"}"#)?.kind == .turnAborted)
        #expect(grok(#"{"hook_event_name":"StopFailure","sessionId":"01a0","error":"rate_limit"}"#)?.kind == .turnAborted)
        #expect(grok(#"{"hook_event_name":"Notification","sessionId":"01a0","notificationType":"permission_prompt"}"#)?.kind
                == .needsInput("Needs your permission"))
        #expect(grok(#"{"hook_event_name":"Notification","sessionId":"01a0","notificationType":"idle_prompt"}"#) == nil)
        #expect(grok(#"{"hook_event_name":"SessionEnd","sessionId":"01a0","subagentType":"explore"}"#) == nil)
        #expect(grok(#"{"hook_event_name":"PreToolUse","sessionId":"child","toolName":"grep","subagentType":"explore"}"#) == nil)
    }

    @Test func grokPayloadViaClaudeHelperIsStillGrok() {
        // Grok scans ~/.claude/settings.json, so gobbl-agent is called with "claude".
        let json = #"{"hookEventName":"user_prompt_submit","hook_event_name":"UserPromptSubmit","sessionId":"01a0","cwd":"/src/app"}"#
        let e = AgentEvent.parse(source: .claude, json: Data(json.utf8))
        #expect(e?.source == .grok)
        #expect(e?.kind == .promptSubmitted)
        #expect(AgentEvent.parse(source: .claude, json: Data(#"{"hook_event_name":"UserPromptSubmit","session_id":"s1"}"#.utf8))?.source
                == .claude)
    }
}

@Suite struct AgentTrackerTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 5_000)

    private func ev(_ kind: AgentEvent.Kind, _ id: String = "s1") -> AgentEvent {
        AgentEvent(source: .claude, sessionID: id, cwd: "/src/gobbl", kind: kind)
    }

    @Test func workThenDone() {
        var t = AgentTracker()
        #expect(t.apply(ev(.promptSubmitted), now: t0, hostApp: "com.mitchellh.ghostty") == .startedWorking)
        #expect(t.apply(ev(.toolUse("Edit")), now: t0) == .none)
        #expect(t.anyWorking)
        #expect(t.sessions[0].project == "gobbl")
        #expect(t.sessions[0].hostApp == "com.mitchellh.ghostty")
        #expect(t.apply(ev(.turnDone("ok")), now: t0) == .done("ok"))
        #expect(!t.anyWorking)
        #expect(t.apply(ev(.turnDone("ok")), now: t0) == .none)
    }

    @Test func legacyCodexNotifyCheersEveryTurn() {
        // Legacy notify sends only turnDone; a later turn must still cheer.
        var t = AgentTracker()
        let done = { AgentEvent(source: .codex, sessionID: "codex:/src/x", cwd: "/src/x", kind: .turnDone($0)) }
        #expect(t.apply(done("one"), now: t0) == .done("one"))
        #expect(t.apply(done("one"), now: t0.addingTimeInterval(1)) == .none)
        #expect(t.apply(done("two"), now: t0.addingTimeInterval(90)) == .done("two"))
    }

    @Test func stopReasonOnlyEndsGrokSessions() {
        #expect(AgentEvent.parse(source: .codex, json: Data(#"{"hook_event_name":"Stop","session_id":"s","reason":"other"}"#.utf8))?.kind
                == .turnDone(nil))
        #expect(AgentEvent.parse(source: .claude, json: Data(#"{"hook_event_name":"Stop","session_id":"s","reason":"other"}"#.utf8))?.kind
                == .turnDone(nil))
        #expect(AgentEvent.parse(source: .grok, json: Data(#"{"hook_event_name":"Stop","sessionId":"s","reason":"shutdown"}"#.utf8))?.kind
                == .sessionEnd)
    }

    @Test func thinkingVersusCoding() {
        var t = AgentTracker()
        #expect(t.activity == .idle)
        t.apply(ev(.promptSubmitted), now: t0)
        #expect(t.activity == .thinking)
        t.apply(ev(.toolUse("Edit")), now: t0)
        #expect(t.activity == .coding)
        t.apply(ev(.toolFinished), now: t0)
        #expect(t.activity == .thinking)
        t.apply(ev(.promptSubmitted, "s2"), now: t0)
        t.apply(ev(.toolUse("Bash"), "s2"), now: t0)
        #expect(t.activity == .coding) // any session coding wins
        t.apply(ev(.turnDone(nil)), now: t0)
        t.apply(ev(.turnDone(nil), "s2"), now: t0)
        #expect(t.activity == .idle)
    }

    @Test func permissionThenResolve() {
        var t = AgentTracker()
        t.apply(ev(.promptSubmitted), now: t0)
        #expect(t.apply(ev(.permissionRequest(tool: "Bash", detail: "ls")), now: t0) == .needsYou("Wants to use Bash"))
        // The generic notification for the same prompt adds nothing.
        #expect(t.apply(ev(.needsInput("Needs your permission")), now: t0) == .none)
        t.resolveWaiting("s1", now: t0)
        #expect(t.anyWorking)
    }

    @Test func sessionsExpire() {
        var t = AgentTracker()
        t.apply(ev(.promptSubmitted, "a"), now: t0)
        t.apply(ev(.turnDone(nil), "b"), now: t0)
        t.expire(now: t0.addingTimeInterval(AgentTracker.staleWorking + 1))
        #expect(!t.anyWorking)
        #expect(t.sessions.count == 2)
        t.expire(now: t0.addingTimeInterval(AgentTracker.forgetDone + 1))
        #expect(t.sessions.isEmpty)
    }

    @Test func sessionEndRemoves() {
        var t = AgentTracker()
        t.apply(ev(.promptSubmitted), now: t0)
        t.apply(ev(.sessionEnd), now: t0)
        #expect(t.sessions.isEmpty)
    }

    @Test func grokEventRelabelsAClaudeRow() {
        var t = AgentTracker()
        t.apply(AgentEvent(source: .claude, sessionID: "s1", cwd: "/src/app", kind: .promptSubmitted), now: t0)
        #expect(t.sessions[0].source == .claude)
        t.apply(AgentEvent(source: .grok, sessionID: "s1", cwd: "/src/app", kind: .toolUse("read_file")), now: t0)
        #expect(t.sessions[0].source == .grok)
    }

    @Test func abortedTurnGoesIdleWithoutCheering() {
        var t = AgentTracker()
        t.apply(ev(.promptSubmitted), now: t0)
        t.apply(ev(.toolUse("Edit")), now: t0)
        #expect(t.apply(ev(.turnAborted), now: t0) == .none)
        #expect(!t.anyWorking)
        #expect(t.sessions[0].state == .idle)
    }
}

@Suite struct AgentHookConfigTests {
    let helper = "/Users/me/Library/Application Support/Gobbl/bin/gobbl-agent"

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func installsAlongsideExistingHooksAndSettings() throws {
        let existing = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let out = try AgentHookConfig.installClaude(into: Data(existing.utf8), helper: helper, approvals: false)
        let root = try object(out)
        #expect(root["model"] as? String == "opus")
        let hooks = try #require(root["hooks"] as? [String: Any])
        let stop = try #require(hooks["Stop"] as? [[String: Any]])
        #expect(stop.count == 2) // theirs + ours
        #expect(hooks["PermissionRequest"] == nil)
        #expect(AgentHookConfig.claudeStatus(out) == (true, false))
    }

    @Test func reinstallIsIdempotentAndApprovalsToggle() throws {
        let once = try AgentHookConfig.installClaude(into: nil, helper: helper, approvals: true)
        let twice = try AgentHookConfig.installClaude(into: once, helper: helper, approvals: true)
        let hooks = try #require(try object(twice)["hooks"] as? [String: Any])
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 1)
        #expect(AgentHookConfig.claudeStatus(twice) == (true, true))
        let off = try AgentHookConfig.installClaude(into: twice, helper: helper, approvals: false)
        #expect(AgentHookConfig.claudeStatus(off) == (true, false))
    }

    @Test func uninstallLeavesOnlyTheirs() throws {
        let existing = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let installed = try AgentHookConfig.installClaude(into: Data(existing.utf8), helper: helper, approvals: true)
        let removed = try AgentHookConfig.uninstallClaude(from: installed)
        let hooks = try #require(try object(removed)["hooks"] as? [String: Any])
        #expect(Array(hooks.keys) == ["Stop"])
        #expect(AgentHookConfig.claudeStatus(removed) == (false, false))
    }

    @Test func refusesToClobberInvalidJSON() {
        #expect(throws: AgentHookConfig.ConfigError.notJSONObject) {
            try AgentHookConfig.installClaude(into: Data("[1,2]".utf8), helper: helper, approvals: false)
        }
    }

    @Test func codexHooks() throws {
        let existing = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let installed = try AgentHookConfig.installCodex(into: Data(existing.utf8), helper: helper, approvals: true)
        let hooks = try #require(try object(installed)["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(AgentHookConfig.codexEvents + ["PermissionRequest"]))
        #expect(hooks["Notification"] == nil) // Codex has no Notification event
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2) // theirs + ours
        let ours = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(ours.first?["command"] as? String == "/usr/bin/perl \"\(helper)\" codex")
        #expect(ours.first?["async"] as? Bool == true)
        #expect(AgentHookConfig.codexStatus(installed) == (true, true))
        #expect(try AgentHookConfig.installCodex(into: installed, helper: helper, approvals: true) == installed)

        let removed = try AgentHookConfig.uninstallCodex(from: installed)
        #expect(Array(try #require(try object(removed)["hooks"] as? [String: Any]).keys) == ["Stop"])
        #expect(AgentHookConfig.codexStatus(removed) == (false, false))
    }

    @Test func grokHooks() throws {
        let existing = #"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let installed = try AgentHookConfig.installGrok(into: Data(existing.utf8), helper: helper)
        let hooks = try #require(try object(installed)["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(AgentHookConfig.grokEvents))
        #expect(hooks["PermissionRequest"] == nil)
        #expect((hooks["Stop"] as? [[String: Any]])?.count == 2) // theirs + ours
        let ours = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        #expect(ours.first?["command"] as? String == "/usr/bin/perl \"\(helper)\" grok")
        #expect(ours.first?["async"] as? Bool == nil)
        #expect((ours.first?["timeout"] as? Int) == 5 || (ours.first?["timeout"] as? NSNumber)?.intValue == 5)
        #expect(AgentHookConfig.grokStatus(installed) == (true, false))
        #expect(try AgentHookConfig.installGrok(into: installed, helper: helper) == installed)

        let removed = try AgentHookConfig.uninstallGrok(from: installed)
        #expect(Array(try #require(try object(removed)["hooks"] as? [String: Any]).keys) == ["Stop"])
        #expect(AgentHookConfig.grokStatus(removed) == (false, false))
    }

    @Test func legacyCodexNotifyIsRemovedButOthersStay() {
        let ours = "notify = [\"/usr/bin/perl\", \"\(helper)\", \"codex\"] # added by Gobbl\nmodel = \"gpt-5\"\n"
        #expect(AgentHookConfig.hasLegacyCodexNotify(ours))
        #expect(AgentHookConfig.removeLegacyCodexNotify(from: ours) == "model = \"gpt-5\"\n")

        let theirs = "notify = [\"/usr/bin/env\", \"node\", \"/Users/me/.tokentracker/bin/notify.cjs\"]\nmodel = \"gpt-5\"\n"
        #expect(!AgentHookConfig.hasLegacyCodexNotify(theirs))
        #expect(AgentHookConfig.removeLegacyCodexNotify(from: theirs) == theirs)
    }
}
