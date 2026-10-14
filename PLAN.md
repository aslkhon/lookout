# Lookout — Plan (v1)

A native macOS menu bar app that monitors Claude Code and Codex agents running in
your existing terminals (VS Code, Ghostty), shows their state, notifies you when they
need attention, and jumps to their window on click. It never launches or wraps agents.

## Decisions
- **Scope:** local Mac only. The event protocol carries a `host` field so remote machines can be added later.
- **UI:** menu bar only (`MenuBarExtra`), with a badge showing how many agents need attention.
- **Stack:** Swift 6 / SwiftUI, macOS 14+. Built as a Swift Package plus an Xcode app target.
- **Focus targets:** VS Code (and Cursor if installed), and Ghostty. Any other terminal gets a generic fallback: activate the app.

Environment: Xcode 26.6, Swift 6.3.3, Claude Code 2.1.300, codex-cli 0.162.1, Ghostty, VS Code.

## Architecture

```
claude / codex ──hook──▶ lookout-hook (tiny CLI) ──unix socket──▶ Lookout.app
                                                                  ├─ SessionStore (state machine)
                                                                  ├─ MenuBarExtra UI
                                                                  ├─ Notifier (UserNotifications)
                                                                  └─ Focuser (VS Code / Ghostty / fallback)
```

### Components
1. **`lookout-hook`**: a Swift CLI bundled inside the app at `Contents/MacOS/lookout-hook`.
   - Reads the hook JSON from stdin and adds context: `source` (claude|codex), PID chain,
     `TERM_PROGRAM`, TTY, `VSCODE_*` / `GHOSTTY_*` environment variables, cwd and a timestamp.
   - Writes one JSON line to `~/Library/Application Support/Lookout/lookout.sock` and exits.
   - Never blocks the agent: 200ms connect timeout, always exits 0, writes nothing to stdout.
2. **Event server**: a Unix domain socket listener built on the Network framework.
3. **SessionStore**: sessions are keyed by `source + session_id`. States:
   - `working`: set on UserPromptSubmit, PreToolUse or PostToolUse.
   - `needsApproval`: set on PermissionRequest or a Notification with type permission_prompt.
   - `needsInput`: set on PreToolUse(AskUserQuestion) or a Notification with type idle_prompt.
   - `finished`: set on Stop.
   - `ended`: set on SessionEnd, or when the liveness scan finds the process has died.
4. **Liveness scan**: every 10s, checks the recorded agent PID with `kill(pid, 0)`. Ended sessions are pruned after N minutes.
5. **Notifier**: posts a notification on any transition into `needsApproval`, `needsInput` or `finished`.
   - Skipped when the agent's host app is frontmost.
   - Clicking a notification focuses the agent.
6. **Focuser**:
   - VS Code / Cursor: run `open -a "Visual Studio Code" <workspace-or-cwd>`, which focuses the existing window for that folder.
     Selecting the exact terminal tab is deferred; it would need a companion extension.
   - Ghostty: activate the app by PID, then use the Accessibility API (AXUIElement) to raise the
     window whose title matches the session's cwd or TTY. Ghostty's native scripting is used instead if the spike finds it supported.
   - Fallback: activate the terminal app found by walking up the parent processes.
7. **Installer**: on first run and from Settings, Lookout installs hooks into:
   - `~/.claude/settings.json`: merged idempotently, with a backup, with entries tagged so they can be uninstalled cleanly.
   - `~/.codex/config.toml`: `notify` and/or hooks, depending on what the spike finds.

## Phases and verification
1. **Spike.** Install a logging hook for both CLIs, run real sessions, and capture the payloads.
   Confirm the Codex hook/notify surface in 0.162.1, the Claude PermissionRequest/Notification types,
   and what VS Code and Ghostty expose in the environment.
   → verify: `fixtures/` contains real recorded payloads for every state.
2. **Core.** Build the hook CLI, socket server, SessionStore and menu bar list.
   → verify: unit tests replay the fixtures and assert the state transitions; then a manual run with 2 live agents.
3. **Notifications + focus.**
   → verify: clicking from both the list and a notification lands on the right VS Code and Ghostty windows.
4. **Installer + polish.** Add hook install/uninstall, launch at login, and a Settings window covering notification toggles, an ignore list and Accessibility permission.
   → verify: a fresh install on a clean user config works end to end; uninstall restores the original config.
5. **Later.** Remote machines (SSH reverse tunnel or Tailscale), a VS Code extension for exact terminal focus, and a signed and notarized DMG.
