import AppKit
import GobblCore
import ServiceManagement
import SwiftUI

/// First run: unbox the computer (the reveal people screenshot), grant optional
/// permissions, learn the three gestures. Every permission is skippable.
@MainActor
enum Onboarding {
    private static var window: NSWindow?

    static func showIfNeeded() {
        if !UserDefaults.standard.bool(forKey: "onboarded") { show() }
    }

    static func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 480),
                         styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.backgroundColor = .black
        w.contentView = NSHostingView(rootView: OnboardingView(done: finish))
        w.center()
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    static func finish() {
        UserDefaults.standard.set(true, forKey: "onboarded")
        window?.close()
        window = nil
        NotchController.shared.open(tab: .home, focus: false)
    }
}

struct OnboardingView: View {
    let done: () -> Void
    @State private var step = 0

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: UnboxStep { withAnimation(.gob) { step = 1 } }
                case 1: PermissionsStep()
                default: TipsStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))

            if step > 0 {
                HStack {
                    HStack(spacing: 6) {
                        ForEach(0..<3) { i in
                            Circle().fill(i == step ? Palette.accent : Palette.wellHover).frame(width: 6, height: 6)
                        }
                    }
                    Spacer()
                    Button(step == 2 ? "Let's go" : "Continue") {
                        if step == 2 { done() } else { withAnimation(.gob) { step += 1 } }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, 36)
        .padding(.top, 40)
        .padding(.bottom, 28)
        .frame(width: 520, height: 480)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.vertical, 9)
            .background(Capsule().fill(Palette.accent))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.gob, value: configuration.isPressed)
    }
}

// MARK: - Permissions

private struct PermissionsStep: View {
    @State private var pet = PetModel.shared
    @State private var calendar = CalendarModel.shared
    @State private var trusted = MediaKeyTap.isTrusted
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var agentsLinked = AgentLink.claudeStatus().connected || AgentLink.codexConnected() || AgentLink.grokConnected()
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Give \(pet.name) some superpowers").font(.system(size: 22, weight: .bold, design: .rounded))
            Text("All optional. Nothing leaves your Mac.")
                .font(.system(size: 13)).foregroundStyle(Palette.textSecondary)
                .padding(.bottom, 6)
            PermissionRow(symbol: "speaker.wave.2.fill", title: "Volume & brightness in the notch",
                          detail: "Replaces the system popups. Needs Accessibility.", granted: trusted) {
                UserDefaults.standard.set(true, forKey: "hudReplace")
                MediaKeyTap.requestTrust()
            }
            PermissionRow(symbol: "calendar", title: "Your next meeting",
                          detail: "Gob nudges you five minutes before it starts.", granted: calendar.authorized) {
                Task { await calendar.requestAccess() }
            }
            if AgentLink.claudeInstalled || AgentLink.codexInstalled || AgentLink.grokInstalled {
                PermissionRow(symbol: "sparkles", title: "Cheer on your AI agents",
                              detail: "Gob works along with Claude Code, Codex and Grok, and celebrates when they finish.",
                              granted: agentsLinked) {
                    if AgentLink.claudeInstalled { try? AgentLink.connectClaude(approvals: false) }
                    if AgentLink.codexInstalled { try? AgentLink.connectCodex() }
                    if AgentLink.grokInstalled { try? AgentLink.connectGrok() }
                    agentsLinked = AgentLink.claudeStatus().connected || AgentLink.codexConnected() || AgentLink.grokConnected()
                }
            }
            PermissionRow(symbol: "power", title: "Open at login",
                          detail: "So Gob is there every morning.", granted: launchAtLogin) {
                try? SMAppService.mainApp.register()
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onReceive(poll) { _ in
            let now = MediaKeyTap.isTrusted
            guard now != trusted else { return }
            trusted = now
            HUDService.apply()
        }
    }
}

private struct PermissionRow: View {
    let symbol: String
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.well))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            if granted {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 18)).foregroundStyle(Palette.accent)
            } else {
                Button("Allow", action: action).controlSize(.large)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Palette.well))
    }
}

// MARK: - Tips

private struct TipsStep: View {
    @State private var pet = PetModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("How \(pet.name) helps").font(.system(size: 22, weight: .bold, design: .rounded))
            tip("tray.and.arrow.down.fill", "Drop files on the notch", "Gob keeps them on the shelf until you drag them out. Right-click a file to convert, compress or copy its text.")
            tip("doc.on.clipboard.fill", "⇧⌘Space opens your clipboard", "Everything you copied, searchable. Passwords are never saved.")
            tip("hand.tap.fill", "Hover the notch, click Gob", "Music, your next meeting, a focus timer, and one very happy pet.")
            tip("square.and.arrow.up.fill", "Show off your pet", "Right-click Gob to share their card.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tip(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13.5, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
