# Backlog

## Features
- **More agents:** Cursor's CLI (not installed here, so untested). Gemini CLI and OpenCode on ssh hosts; today they're watched on this Mac only.
- **Answer Gemini CLI and OpenCode from Lookout:** Gemini's hooks can't answer its permission prompts. OpenCode's plugin could, through its API.
- **Token counts for Gemini CLI and OpenCode:** the usage chart and session cost only read Claude Code's and Codex's transcripts.
- **Notch:** questions and plans in the notch (⌘1–3); a setting for which screen it uses.

## Known issues
- When two subagents ask for permission at the same time, Lookout can only answer the newer request.
- A Codex model switch reprices the whole session at the new model's prices.
- Editing in full-screen Keynote counts as presenting, so notifications go silent.
- Unverified: whether the microphone's StatusIndicator also counts as screen sharing.
- ssh runs to remote hosts aren't cancelled when they're no longer needed.
- The Codex session index is re-read for every event.
- The first open of Usage reads every transcript of the last 30 days (about 10 s for 1.3 GB); later opens read only changed files.
