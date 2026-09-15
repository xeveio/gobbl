import SwiftUI

/// Connect / disconnect Claude Code, Codex and Grok. Nothing is changed in their
/// config files until the user flips a switch here (or in onboarding).
struct AgentsSettingsSection: View {
    @State private var claude = AgentLink.claudeStatus()
    @State private var codex = AgentLink.codexConnected()
    @State private var grok = AgentLink.grokConnected()
    @State private var error: String?

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { claude.connected }, set: { setClaude($0, approvals: claude.approvals) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code")
                    Text(AgentLink.claudeInstalled ? "Adds Gobbl hooks to ~/.claude/settings.json" : "Claude Code isn't set up on this Mac yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if claude.connected {
                Toggle(isOn: Binding(get: { claude.approvals }, set: { setClaude(true, approvals: $0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Approve permission prompts from the notch")
                        Text("Allow or Deny without switching to the terminal. Unanswered after 30 s, Claude asks in the terminal as usual.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle(isOn: Binding(get: { codex }, set: setCodex)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Codex")
                    Text(AgentLink.codexInstalled ? "Adds hooks to ~/.codex/hooks.json" : "Codex isn't set up on this Mac yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle(isOn: Binding(get: { grok }, set: setGrok)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grok")
                    Text(AgentLink.grokInstalled ? "Adds Gobbl hooks to ~/.grok/hooks/gobbl.json" : "Grok isn't set up on this Mac yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            }
            if claude.connected || codex || grok {
                Button("Send a Test Event") { AgentLink.sendTest() }
            }
        } header: {
            Text("AI Agents")
        } footer: {
            Text("Gob works along while your agent runs and cheers when it finishes. Events go to Gobbl through a private socket on this Mac; nothing is sent anywhere. Each file is backed up to .gobbl-backup before it's changed.")
                .font(.caption).foregroundStyle(.secondary)
        }
        MCPConnectorSection()
    }

    private func setClaude(_ on: Bool, approvals: Bool) {
        do {
            if on { try AgentLink.connectClaude(approvals: approvals) } else { try AgentLink.disconnectClaude() }
            error = nil
        } catch {
            self.error = AgentLink.describe(error)
        }
        claude = AgentLink.claudeStatus()
    }

    private func setCodex(_ on: Bool) {
        do {
            if on { try AgentLink.connectCodex() } else { try AgentLink.disconnectCodex() }
            error = nil
        } catch {
            self.error = AgentLink.describe(error)
        }
        codex = AgentLink.codexConnected()
    }

    private func setGrok(_ on: Bool) {
        do {
            if on { try AgentLink.connectGrok() } else { try AgentLink.disconnectGrok() }
            error = nil
        } catch {
            self.error = AgentLink.describe(error)
        }
        grok = AgentLink.grokConnected()
    }
}

/// One switch that connects every AI app on this Mac to Gobbl's memory (MCP).
struct MCPConnectorSection: View {
    @State private var connector = MCPConnector.shared
    @State private var copied = false

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { connector.autoConnect }, set: { connector.setAutoConnect($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Connect AI apps automatically")
                    Text("Claude, ChatGPT, Cursor and others can search your memory, to-dos and people, and set reminders. Answers come from this Mac.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .disabled(connector.busy)
            if connector.loaded && connector.rows.isEmpty {
                Text("No AI apps found on this Mac.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(connector.rows) { row in
                HStack(spacing: 8) {
                    Circle().fill(color(row.status)).frame(width: 8, height: 8)
                    Text(row.client.name)
                    Spacer()
                    if connector.busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(detail(row)).font(.caption).foregroundStyle(connector.restartNeeded.contains(row.id) ? .orange : .secondary)
                    }
                }
            }
            HStack {
                Text(MCPLink.shimURL.path)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    try? MCPLink.installShim()
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(MCPLink.shimURL.path, forType: .string)
                    copied = true
                }
            }
            if connector.requestCount > 0 {
                Text(requestsLabel).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Memory for AI apps")
        } footer: {
            Text("For any other app, add an MCP server that runs the command above. Only the tool name and time of each request are logged, in mcp-requests.jsonl.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { connector.refresh() }
    }

    private var requestsLabel: String {
        var s = connector.requestCount == 1 ? "1 request from AI apps" : "\(connector.requestCount) requests from AI apps"
        if let last = connector.lastRequest { s += ", last " + last.formatted(.relative(presentation: .named)) }
        return s
    }

    private func color(_ status: MCPLink.Status) -> Color {
        switch status {
        case .connected: .green
        case .notConnected: .secondary.opacity(0.5)
        case .manual: .orange
        case .failed: .red
        }
    }

    private func detail(_ row: MCPConnector.Row) -> String {
        switch row.status {
        case .connected: connector.restartNeeded.contains(row.id) ? "Restart needed" : "Connected"
        case .notConnected: connector.restartNeeded.contains(row.id) ? "Restart needed" : "Not connected"
        case .manual(let why), .failed(let why): why
        }
    }
}
