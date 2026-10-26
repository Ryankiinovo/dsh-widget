# DSH Widget

**English** · [简体中文](README.zh-CN.md)

A macOS desktop widget for the DeepSeek Harness desktop app: keep the current session on your desktop, send messages without switching windows, and watch streaming replies.

[English](README.md) | [简体中文](README.zh-CN.md)

> Unofficial community project. Not affiliated with DeepSeek.
> Early release: **Apple Silicon / macOS 14+**, ad-hoc signed and **not notarized**.

![status](https://img.shields.io/badge/status-early%20preview-orange)

**Latest release:** [v0.4.0](https://github.com/Ryankiinovo/dsh-widget/releases/tag/v0.4.0)

## What it does

- Resides at the desktop window level: below normal app windows, above the wallpaper.
- Lists sessions in the current workspace and switches between them.
- Sends prompts and renders streaming assistant replies. The composer supports multiple lines: **Enter sends, Shift+Enter inserts a newline**.
- Opens a session with a ~200-message window and loads older pages on demand ("Load earlier"); keeps a local cache, and a sync button fills gaps after disconnects.
- Supports basic Markdown: paragraphs, headings, lists, quotes, rules, code blocks, bold/italic/inline code and links.
- Shows a workspace menu and can create a new session in the current workspace.
- While the agent runs, a status row stays at the end of the session: breathing lamp (green = thinking/writing, blue = running a tool, yellow = waiting or error), action name, elapsed timer, step number, a tick strip, the last three reasoning segments, and a trace of the last three tool calls.
- Images inside messages render as a thumbnail strip (56pt, up to 9 per row, then +N); click to open the viewer and flip with ←/→, close with Esc. Paste or drag image files into the composer.
- Phone pairing: the QR button in the header opens a card (white-background QR, six-digit code, countdown, candidate addresses); the mobile client pairs by scanning. Paired device tokens can be revoked individually.
- Pairing from the DSH settings page too: Settings → "Widget" shows whether the app is running (with a Start button when it is not) and generates a QR code plus six-digit code on demand, with a 120-second countdown and a Refresh button once it expires; the local and public addresses embedded in the code are listed underneath, flagged when the public one is unreachable. Pair a new device without opening the app.
- Optional remote access: `src/scripts/tunnel.sh` starts a Cloudflare quick tunnel and writes the address to `~/.dsh/widget-public-url`; `install-launchd.sh` installs it as a user-level launchd service (starts at login, restarts on crash, survives DSH quitting). `GET /v1/endpoints` lets the client refresh candidate addresses, so a new tunnel hostname no longer requires re-pairing.

## Requirements

- macOS 14 or newer on Apple Silicon.
- DeepSeek Harness desktop app installed and running.
- The **dsh-widget-bridge** plugin installed into the DSH desktop profile.
- To build from source: Xcode Command Line Tools and Node.js 22+.

> The DMG contains the app only. The bridge plugin is required and is installed from the source tree.

## Install

### 1. Install the bridge plugin

```bash
git clone https://github.com/Ryankiinovo/dsh-widget.git
cd dsh-widget
./src/scripts/install.sh
```

The script:

1. Symlinks `src/bridge` into `~/.dsh/profiles/desktop/node_modules/dsh-widget-bridge`.
2. Backs up `~/.dsh/profiles/desktop/cordis.patch.yml` and adds the plugin entry once.

Then **fully quit DSH (Cmd+Q) and reopen it**. Closing the window is not enough; the plugin loads at host startup. If `~/.dsh/widget-bridge.json` appears, the bridge is running.

### 2. Install the app

Download the latest `DSHWidget-<version>-macos-arm64.dmg` from Releases, open it, and drag `DSHWidget.app` to `Applications`.

Because this build is ad-hoc signed and not notarized, Gatekeeper may block the first launch. Use **right-click → Open**, or:

```bash
xattr -dr com.apple.quarantine /Applications/DSHWidget.app
```

Only do this for a build you trust. A future release can be Developer ID signed and notarized.

### 3. Launch

Open `DSHWidget.app`. The widget starts at the top-right of the desktop; drag its edges to resize. If it shows “waiting for DSH”, start DSH or reopen it so the bridge can write its discovery file.

## Build from source

```bash
git clone https://github.com/Ryankiinovo/dsh-widget.git
cd dsh-widget

# 1. Install the bridge into the DSH desktop profile
./src/scripts/install.sh

# 2. Build the app (native architecture; currently arm64)
./src/macos/build.sh

# 3. Optional: build a DMG
./src/scripts/make-dmg.sh --skip-build

# 4. Run
open dist/DSHWidget.app
```

The DMG is written to `dist/DSHWidget-<version>-macos-<arch>.dmg` with a `.sha256` file.

### Tests

```bash
node --check src/bridge/index.js
node src/bridge/test-mock.mjs
./src/scripts/verify-widget.sh
tail -n 20 ~/.dsh/widget-verify.log
```

The mock test does not need a running DSH host.

## How it works

```text
DSH Host
  └─ dsh-widget-bridge plugin (src/bridge)
       ├─ HTTP + SSE on 127.0.0.1:<random port>
       ├─ writes ~/.dsh/widget-bridge.json (pid/port/token, mode 0600)
       └─ calls DSH session controller: list/create/prompt/cancel/follow/page
                 ▲
                 │ Bearer token
                 ▼
        DSHWidget.app (src/macos)
          ├─ reads discovery, loads full history, then follows SSE
          └─ desktop-level NSPanel
```

The bridge does not duplicate DSH business logic; it exposes existing session capabilities as a local HTTP/SSE API. The app does not read DSH cookies, launch tokens, Keychain items or API keys.

## Security

- Listens on `127.0.0.1` only, with a random port and a random per-host token.
- Rejects requests carrying a browser `Origin` header.
- Discovery file is mode `0600`; treat it as a local secret.
- Request body limit 1 MB; history pages are capped at 500 records.
- No telemetry.

## Known limitations

- Apple Silicon only; Intel Macs are not supported by this build.
- macOS 14+.
- Ad-hoc signed, not notarized; first launch needs right-click Open or quarantine removal.
- Requires a running DSH desktop host and the bridge plugin.
- Markdown is a basic subset; tables, raw HTML and deeply nested structures are not rendered.
- Desktop window level: full-screen apps cover the widget by design.
- No protocol version negotiation; a future DSH release may change the plugin API.
- A session opens with a ~200-message window; older pages load on demand. Full imports (`?all=1`) are capped at 200 pages.
- Cloudflare quick tunnels buffer `text/event-stream` bodies for roughly 40–50 seconds. On cellular the client falls back to polling: history and prompts work, but the live "thinking" status row does not. For reliable streaming, use a self-hosted tunnel (frp + Caddy or a Cloudflare named tunnel).

## License

MIT License. See [LICENSE](LICENSE).

Copyright (c) 2026 Ryankiin.

## Contributing

Issues and pull requests are welcome. Please do not include tokens, DSH discovery files, private session content or screenshots containing personal data.

Before submitting:

```bash
node --check src/bridge/index.js
node src/bridge/test-mock.mjs
./src/macos/build.sh
```
