# Lookout

A macOS menu bar app that shows the state of every Claude Code and Codex agent on your Mac:
working, needs approval, needs input, or finished. It notifies you when one needs attention,
and clicking an agent jumps to its terminal. You keep launching agents however you like.

## Install

```sh
brew install --cask aslkhon/tap/lookout
```

Or download `Lookout-<version>.zip` from [Releases](https://github.com/aslkhon/lookout/releases)
and move `Lookout.app` to `/Applications`. Requires macOS 14 or later.

> Lookout isn't notarized yet, so macOS blocks it on first launch. Open
> **System Settings › Privacy & Security** and click **Open Anyway**, or run
> `xattr -dr com.apple.quarantine /Applications/Lookout.app`.

To uninstall, remove the hooks first (**Setup… → Remove Hooks**), then run
`brew uninstall --zap --cask lookout`.

## Build & run

```sh
./scripts/build-app.sh      # → build/Lookout.app + build/Lookout-<version>.zip (universal, ad-hoc signed)
open build/Lookout.app
swift test                  # state machine + installer tests (replays real hook payloads)
```

On first launch Lookout shows a setup window that:

- adds hook entries to `~/.claude/settings.json`;
- adds hook entries to `~/.codex/hooks.json` and marks them trusted in `~/.codex/config.toml`
  (through `codex app-server`, so Codex writes its own config);
- asks for notification permission.

Existing hooks are kept, and each file is backed up as `<file>.lookout-backup-<timestamp>`.
To remove the hooks, open **Setup… → Remove Hooks**.

Clicking an agent jumps to its terminal. **Open Window** in the menu opens a dashboard, which
filters agents by status or project and shows details for the selected one.

## How it works

```
claude / codex ──hook──▶ ~/.lookout/bin/lookout-hook ──unix socket──▶ Lookout.app
```

- `lookout-hook` reads the hook JSON, adds the agent PID, TTY and host app (`__CFBundleIdentifier`),
  sends it to `~/.lookout/lookout.sock`, and exits 0 without printing anything.
  It takes about 20ms. If Lookout isn't running, it silently does nothing.
- `SessionReducer` (in `LookoutCore`) maps hook events to statuses. A 5s liveness check marks
  sessions as ended when their agent process exits.
- Clicking an agent:
  - **Ghostty**: focuses the terminal whose working directory matches, through Ghostty's
    AppleScript dictionary. macOS asks for Automation permission once.
  - **VS Code / Cursor**: reopens the window whose folder contains the agent's cwd, which
    focuses it. VS Code's API doesn't allow selecting the exact terminal tab.
  - **Anything else**: activates the host app.

Debug event flow with:

```sh
/usr/bin/log stream --level debug --predicate 'subsystem == "io.github.aslkhon.lookout"'
```
