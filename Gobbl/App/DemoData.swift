#if DEBUG
import AppKit
import GobblCore
import SwiftUI

/// `--demo`: fills the notch with neutral sample content (a track, a
/// meeting, files on the shelf, agent sessions, a chat) so screenshots for
/// the website never show anyone's real music, files or calendar. Nothing
/// here is saved: the shelf, calendar and chat are replaced in memory only.
@MainActor
enum DemoData {
    static func load() {
        let now = Date()

        var track = NowPlaying()
        track.title = "Weightless"
        track.artist = "Marconi Union"
        track.album = "Weightless"
        track.playing = true
        track.duration = 480
        track.elapsedTime = 187
        MediaController.shared.setDemo(track, artwork: artwork())

        CalendarModel.shared.setDemo([
            .init(id: "demo-review", title: "Design review", start: now.addingTimeInterval(12 * 60),
                  end: now.addingTimeInterval(57 * 60), color: Color(hex: 0x5B8DEF),
                  joinURL: URL(string: "https://zoom.us/j/1234567890"), attendees: ["Samar Mustafa"]),
            .init(id: "demo-standup", title: "Team standup", start: now.addingTimeInterval(3 * 3600),
                  end: now.addingTimeInterval(3 * 3600 + 900), color: Color(hex: 0xA6F25C), joinURL: nil),
        ])

        ShelfModel.shared.setDemo(sampleFiles())

        AgentHub.shared.demo([
            AgentEvent(source: .claude, sessionID: "demo-1", cwd: "/Users/demo/gobbl", kind: .promptSubmitted),
            AgentEvent(source: .claude, sessionID: "demo-1", cwd: "/Users/demo/gobbl", kind: .toolUse("Edit")),
            AgentEvent(source: .codex, sessionID: "demo-2", cwd: "/Users/demo/website", kind: .turnDone("Deployed the new landing page")),
            AgentEvent(source: .grok, sessionID: "demo-4", cwd: "/Users/demo/app", kind: .toolUse("run_terminal_command")),
            AgentEvent(source: .claude, sessionID: "demo-3", cwd: "/Users/demo/api", kind: .needsInput("Needs your permission")),
        ])

        ChatModel.shared.seedDemo()
    }

    /// A few harmless files in a temporary folder, with real icons and thumbnails.
    private static func sampleFiles() -> [URL] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gobbl-demo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let names = ["Q3 deck.pdf", "Trip itinerary.pdf", "Logo.png", "Notes.md"]
        return names.map { name in
            let url = dir.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: url.path) {
                if name.hasSuffix(".png"), let png = artwork()?.pngData() {
                    try? png.write(to: url)
                } else {
                    try? Data("Gobbl demo file".utf8).write(to: url)
                }
            }
            return url
        }
    }

    /// Soft gradient artwork, drawn rather than borrowed from a real album.
    private static func artwork() -> NSImage? {
        let size = NSSize(width: 256, height: 256)
        let image = NSImage(size: size)
        image.lockFocus()
        let gradient = NSGradient(colors: [NSColor(red: 0.24, green: 0.36, blue: 0.62, alpha: 1),
                                           NSColor(red: 0.55, green: 0.33, blue: 0.62, alpha: 1),
                                           NSColor(red: 0.93, green: 0.55, blue: 0.45, alpha: 1)])
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -45)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(ovalIn: NSRect(x: 70, y: 70, width: 116, height: 116)).fill()
        image.unlockFocus()
        return image
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
#endif
