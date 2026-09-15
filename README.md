# Gobbl

Your notch has a pet. Gob lives in your MacBook's notch, gobbles the files you
drop on it, and burps them back out wherever you need them.

Free and open source, by [Xeve](https://xeve.io). Site: https://gobbl.xeve.io

## Features

- **Pet:** Gob, a little computer with a face on its screen: Classic (late-70s), Compact (mid-80s) or Candy (late-90s). Arrives in a box (8 colours, 1 in 100 limited editions). Reacts to what you do: eats files through its slot, dances to music, sleeps when you're away, sweats when the CPU is pegged, fills its screen with Matrix rain while your AI agent codes and ponders while it thinks, types along when you type (opt-in), nudges you before meetings. Levels up, keeps a daily streak, earns 11 hats (4 seasonal). Shareable pet card and clips (see `docs/MASCOT.md`).
- **AI agents:** connect Claude Code, Codex and Grok from Settings; Gob works along, cheers when a task finishes, and can Allow/Deny Claude's permission prompts from the notch (falls back to the terminal after 30 s).
- **Clips:** render 6-second scenes to MP4 + GIF, or record the real notch.
- **Drop basket:** shake while dragging files to get a drop zone at the pointer.
- **Shelf:** drop files on the notch; drag them out, AirDrop, share, Quick Look.
- **File tools:** convert/compress images, compress PDFs and video, remove backgrounds, OCR to clipboard, zip. All on-device.
- **Clipboard history:** ⇧⌘Space, search, pins; skips concealed/transient (password) items.
- **Now playing:** any app, via the bundled [mediaremote-adapter](Vendor/mediaremote-adapter) run by `/usr/bin/perl`.
- **HUDs:** volume, brightness, Caps Lock, charging and low-battery in the notch (optional, needs Accessibility).
- **Calendar:** next meeting with Join link; five-minute nudge.
- **Tools:** focus timer, keep-awake, mic mute, color picker, copy text from the screen; audio output picker and optional synced lyrics (lrclib.net) on the music card.
- Pill mode on Macs without a notch and on external displays; hides for full-screen apps.

## Install

Download the DMG from [gobbl.xeve.io](https://gobbl.xeve.io/download) or [GitHub releases](https://github.com/xeveio/gobbl/releases), or use Homebrew:

```sh
brew trust xeveio/tap        # Homebrew 7+ asks you to trust third-party taps once
brew install --cask xeveio/tap/gobbl
```

Gobbl updates itself (Sparkle). macOS 14 or later.

## Build

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Gobbl.xcodeproj        # or: xcodebuild -scheme Gobbl build
scripts/ci-test.sh          # GobblCore unit tests
```

Debug flags (DEBUG builds): `--expand [--tab home|shelf|clipboard|tools]`, `--mood <mood>`,
`--onboarding`, `--no-onboarding`, `--render-card <dir>`.

## Layout

- `Gobbl/` — the app: notch panels (`Notch/`), Gob (`Pet/`), shelf and file tools (`Shelf/`), clipboard, media, HUDs, system services, onboarding, settings.
- `Packages/GobblCore/` — UI-free logic with tests: notch geometry, Gob's brain and genome, shelf, clipboard history, now-playing stream parsing.
- `Vendor/mediaremote-adapter/` — BSD-3 third-party code, built by `scripts/build-mediaremote.sh`.
- `site/` — gobbl.xeve.io.

## Release

```sh
swift scripts/make-icon.swift                                # app icon + site images
scripts/release.sh 0.1.0 --notes release-notes/0.1.0.md      # build, sign, notarize, DMG, appcast, cask
scripts/release.sh 0.1.0 --notes release-notes/0.1.0.md --upload --github   # publish to dl.xeve.io/gobbl
scripts/deploy-site.sh                                       # Cloudflare Pages project "gobbl"
```

Or push a `gobbl-v<version>` tag (see `.github/workflows/release.yml` for the secrets).
Sparkle's EdDSA key is in the Keychain (account `gobbl`), backed up at
`~/.secrets/gobbl-sparkle-ed25519.key`.

## Clean-room rule

Gobbl is MIT. Never copy code from GPL projects (Boring Notch, Atoll, older
Droppy releases) — read them for ideas only. Record any MIT/BSD code we do use
in `THIRD_PARTY.md`.
