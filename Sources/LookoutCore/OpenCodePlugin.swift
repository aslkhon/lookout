import Foundation

/// OpenCode has no hook commands, only plugins: this one turns its events into the Claude Code
/// hook payloads `lookout-hook` forwards, under Claude's event names.
public enum OpenCodePlugin {
    public static func url(home: URL) -> URL {
        home.appendingPathComponent(".config/opencode/plugins/lookout.js")
    }

    public static func source(hookBinaryPath: String) -> String {
        template.replacingOccurrences(of: "__HOOK__", with: hookBinaryPath)
    }

    // The first line holds HookInstaller.marker, like the other agents' hook entries.
    private static let template = #"""
    // lookout-hook: Lookout's OpenCode plugin. Lookout writes it and rewrites it when it updates.
    import { spawn } from "node:child_process";

    const HOOK = "__HOOK__";

    export const Lookout = async ({ directory }) => {
      const subagents = new Set(); // sessions the task tool starts; their parent's row covers them
      const aborted = new Set();
      const roles = new Map(); // message id → "user" | "assistant"
      const replies = new Map(); // session id → the last reply's text

      const send = (payload) => {
        if (!payload.session_id || subagents.has(payload.session_id)) return;
        try {
          const child = spawn(HOOK, ["opencode"], { stdio: ["pipe", "ignore", "ignore"] });
          child.on("error", () => {});
          child.stdin.on("error", () => {});
          child.stdin.end(JSON.stringify({ cwd: directory, ...payload }));
        } catch {}
      };

      return {
        "chat.message": async (input, output) => {
          const prompt = (output.parts || [])
            .filter((part) => part.type === "text" && !part.synthetic)
            .map((part) => part.text).join("\n");
          send({ session_id: input.sessionID, hook_event_name: "UserPromptSubmit", prompt });
        },
        "tool.execute.before": async (input, output) => {
          send({ session_id: input.sessionID, hook_event_name: "PreToolUse", tool_name: input.tool, tool_input: output.args });
        },
        "tool.execute.after": async (input) => {
          send({ session_id: input.sessionID, hook_event_name: "PostToolUse", tool_name: input.tool, tool_input: input.args });
        },
        event: async ({ event }) => {
          const p = event.properties || {};
          switch (event.type) {
            case "session.created":
              if (p.info?.parentID) subagents.add(p.info.id);
              else send({ session_id: p.info?.id, hook_event_name: "SessionStart", cwd: p.info?.directory || directory });
              break;
            case "session.deleted":
              send({ session_id: p.info?.id, hook_event_name: "SessionEnd" });
              break;
            case "message.updated":
              if (p.info?.id) roles.set(p.info.id, p.info.role);
              break;
            case "message.part.updated":
              if (p.part?.type === "text" && roles.get(p.part.messageID) === "assistant") replies.set(p.part.sessionID, p.part.text);
              break;
            case "permission.asked":
            case "permission.updated":
              send({ session_id: p.sessionID, hook_event_name: "Notification", notification_type: "permission_prompt",
                     message: p.title || [p.permission, ...(p.patterns || [])].filter(Boolean).join(" ") || "Permission needed" });
              break;
            case "question.asked":
              send({ session_id: p.sessionID, hook_event_name: "Notification", notification_type: "elicitation_dialog",
                     message: p.questions?.[0]?.question || "Asked a question" });
              break;
            case "permission.replied":
            case "question.replied":
            case "question.rejected":
              send({ session_id: p.sessionID, hook_event_name: "UserPromptSubmit" }); // answered: working again
              break;
            case "session.error":
              if (p.error?.name === "MessageAbortedError" && p.sessionID) {
                aborted.add(p.sessionID);
                send({ session_id: p.sessionID, hook_event_name: "Interrupt" });
              }
              break;
            case "session.idle":
              if (aborted.delete(p.sessionID)) break;
              send({ session_id: p.sessionID, hook_event_name: "Stop", last_assistant_message: replies.get(p.sessionID) });
              break;
          }
        },
      };
    };
    """#
}
