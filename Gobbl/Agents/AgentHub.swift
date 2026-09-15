import AppKit
import GobblCore
import Observation

/// Listens for Claude Code / Codex / Grok events from `gobbl-agent` on a Unix socket
/// and turns them into Gob's moods, notch HUDs, the Agents tab, and — when
/// approvals are on — Allow/Deny prompts answered from the notch.
@MainActor @Observable
final class AgentHub {
    static let shared = AgentHub()

    struct PermissionPrompt: Identifiable {
        let id = UUID()
        let sessionID: String
        let source: AgentEvent.Source
        let project: String
        let tool: String
        let detail: String?
        let created: Date
        let reply: AgentReply

        var deadline: Date { created.addingTimeInterval(AgentHub.approvalWindow) }
    }

    /// How long a notch prompt waits before handing the question back to the terminal.
    static let approvalWindow: TimeInterval = 30

    static let socketURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Gobbl/agent.sock")

    private(set) var tracker = AgentTracker()
    private(set) var pending: [PermissionPrompt] = []

    @ObservationIgnored private var server: AgentSocketServer?
    @ObservationIgnored private var expireTimer: Timer?

    var sessions: [AgentSession] { tracker.sessions }
    var anyWaiting: Bool {
        !pending.isEmpty || sessions.contains { if case .waiting = $0.state { true } else { false } }
    }

    func start() {
        guard server == nil else { return }
        let server = AgentSocketServer(path: Self.socketURL.path) { [weak self] line, reply in
            self?.receive(line, reply: reply)
        }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Gobbl: agent socket failed: \(error)")
        }
        MCPConnector.shared.launch()
    }

    func stop() {
        pending.forEach { $0.reply.close() }
        pending.removeAll()
        server?.stop()
        server = nil
    }

    // MARK: Decisions

    func decide(_ prompt: PermissionPrompt, allow: Bool) {
        let decision: [String: Any] = allow
            ? ["behavior": "allow"]
            // Claude Code reads "reason", Codex reads "message"; each ignores the other.
            : ["behavior": "deny", "reason": "Denied from the Gobbl notch", "message": "Denied from the Gobbl notch"]
        let output: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        if let data = try? JSONSerialization.data(withJSONObject: output), let json = String(data: data, encoding: .utf8) {
            prompt.reply.send(json)
        } else {
            prompt.reply.close()
        }
        finish(prompt)
        HUDModel.shared.show(.init(symbol: allow ? "checkmark.circle.fill" : "xmark.circle.fill",
                                   label: allow ? "Allowed" : "Denied", tint: allow ? Palette.accent : .red), for: 1.5)
        PetModel.shared.send(.agentActivity(tracker.activity))
    }

    /// No answer: Claude Code asks in the terminal as usual.
    func askInTerminal(_ prompt: PermissionPrompt) {
        prompt.reply.close()
        finish(prompt)
    }

    func open(_ session: AgentSession) {
        guard let id = session.hostApp, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    #if DEBUG
    /// `--demo`: sample agent sessions for screenshots.
    func demo(_ events: [AgentEvent]) {
        var t = tracker
        // Spread over the last few minutes so times read "2 min ago", not "in 0s".
        for (i, e) in events.enumerated() {
            _ = t.apply(e, now: Date().addingTimeInterval(-Double(events.count - i) * 150))
        }
        tracker = t
    }
    #endif

    func clearFinished() {
        var t = tracker
        t.expire(now: Date().addingTimeInterval(AgentTracker.forgetDone + 1))
        tracker = t
    }

    // MARK: Events

    private func receive(_ line: String, reply: AgentReply) {
        let parts = line.split(separator: "\t", maxSplits: 1)
        // gobbl-mcp asking for something only the running app has; answered on the same connection.
        if parts.count == 2, parts[0] == "mcp" {
            MCPBridge.handle(String(parts[1]), reply: reply)
            return
        }
        guard parts.count == 2, let claimed = AgentEvent.Source(rawValue: String(parts[0])),
              let event = AgentEvent.parse(source: claimed, json: Data(parts[1].utf8)) else {
            reply.close()
            return
        }
        // The prompt was just typed, so the frontmost app is the terminal or editor running the agent.
        let host = event.kind == .promptSubmitted ? NSWorkspace.shared.frontmostApplication?.bundleIdentifier : nil
        let activityBefore = tracker.activity
        let effect = tracker.apply(event, hostApp: host)
        let project = tracker.sessions.first { $0.id == event.sessionID }?.project ?? event.source.displayName

        if case .permissionRequest(let tool, let detail) = event.kind, UserDefaults.standard.bool(forKey: "agentApprovals") {
            let prompt = PermissionPrompt(sessionID: event.sessionID, source: event.source, project: project, tool: tool,
                                          detail: detail, created: Date(), reply: reply)
            pending.append(prompt)
            NotchController.shared.open(tab: .agents, focus: false)
            NSSound(named: "Tink")?.play()
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(Self.approvalWindow))
                guard let self, self.pending.contains(where: { $0.id == prompt.id }) else { return }
                self.askInTerminal(prompt)
            }
        } else {
            reply.close()
        }

        switch effect {
        case .needsYou:
            PetModel.shared.send(.agentNeedsInput)
            HUDModel.shared.show(.init(symbol: "exclamationmark.bubble.fill", label: short(project), tint: Palette.gold), for: 5)
        case .done:
            PetModel.shared.send(.agentDone)
            HUDModel.shared.show(.init(symbol: "checkmark.circle.fill", label: short(project), tint: Palette.accent), for: 3)
        case .startedWorking, .none:
            break
        }
        // Thinking (reasoning) and coding (running tools) look different on Gob's screen.
        if tracker.activity != activityBefore { PetModel.shared.send(.agentActivity(tracker.activity)) }
        scheduleExpiry()
    }

    private func finish(_ prompt: PermissionPrompt) {
        pending.removeAll { $0.id == prompt.id }
        tracker.resolveWaiting(prompt.sessionID)
        // The prompt opened the notch; once it's answered, get out of the way.
        if pending.isEmpty { NotchController.shared.closeAll() }
    }

    private func short(_ s: String) -> String { s.count > 12 ? String(s.prefix(11)) + "…" : s }

    /// A slow timer, only while there are sessions, to age out stale ones.
    private func scheduleExpiry() {
        if tracker.sessions.isEmpty {
            expireTimer?.invalidate()
            expireTimer = nil
            return
        }
        guard expireTimer == nil else { return }
        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let before = self.tracker.activity
                self.tracker.expire()
                if self.tracker.activity != before { PetModel.shared.send(.agentActivity(self.tracker.activity)) }
                self.scheduleExpiry()
            }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        expireTimer = t
    }
}

// MARK: - Socket

/// The client end of one connection. Closing without sending means "no decision".
final class AgentReply: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32) { self.fd = fd }

    func send(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let bytes = Array((text + "\n").utf8)
        bytes.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        Darwin.close(fd)
        closed = true
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        Darwin.close(fd)
        closed = true
    }

    deinit { close() }
}

/// A user-only (0600) Unix socket. Each client sends one line; the handler
/// runs on the main actor and must eventually close or answer the reply.
final class AgentSocketServer: @unchecked Sendable {
    let path: String
    private let handler: @MainActor (String, AgentReply) -> Void
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.xeve.gobbl.agent-socket")

    init(path: String, handler: @escaping @MainActor (String, AgentReply) -> Void) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: path).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        unlink(path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes) }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll() }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
        unlink(path)
    }

    private func acceptAll() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var timeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
            var noSigPipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            let reply = AgentReply(fd: client)
            guard let line = readLine(client) else {
                reply.close()
                continue
            }
            let handler = self.handler
            DispatchQueue.main.async { MainActor.assumeIsolated { handler(line, reply) } }
        }
    }

    private func readLine(_ fd: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while data.count < 4_000_000 {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
            if buffer[..<n].contains(0x0A) { break }
        }
        guard !data.isEmpty else { return nil }
        let end = data.firstIndex(of: 0x0A) ?? data.endIndex
        return String(decoding: data[data.startIndex..<end], as: UTF8.self)
    }
}
