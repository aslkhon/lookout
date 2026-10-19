import Foundation
import Testing
@testable import LookoutCore

/// Gemini CLI's hooks and OpenCode's plugin.
struct NewAgentsTests {
    func replay(_ lines: [String], source: AgentSource) throws -> [AgentSession] {
        var session: AgentSession?
        return try lines.map { line in
            let payload = try JSONDecoder().decode(HookPayload.self, from: Data(line.utf8))
            let next = SessionReducer.apply(HookEnvelope(source: source, context: HookContext(agentPID: 42), payload: payload), to: session)
            session = next
            return next
        }
    }

    @Test func geminiTurn() throws {
        let base = #""session_id":"g1","cwd":"/Users/dev/app","timestamp":"2026-10-19T10:00:00Z""#
        let sessions = try replay([
            #"{\#(base),"hook_event_name":"SessionStart","source":"startup"}"#,
            #"{\#(base),"hook_event_name":"BeforeAgent","prompt":"run the tests"}"#,
            #"{\#(base),"hook_event_name":"BeforeTool","tool_name":"run_shell_command","tool_input":{"command":"npm test"}}"#,
            #"{\#(base),"hook_event_name":"Notification","notification_type":"ToolPermission","message":"Allow npm test?","details":{}}"#,
            #"{\#(base),"hook_event_name":"AfterTool","tool_name":"run_shell_command","tool_input":{"command":"npm test"}}"#,
            #"{\#(base),"hook_event_name":"AfterAgent","prompt":"run the tests","prompt_response":"All 12 tests pass.\nDone."}"#,
            #"{\#(base),"hook_event_name":"SessionEnd","reason":"exit"}"#,
        ], source: .gemini)
        #expect(sessions.map(\.status) == [.idle, .working, .working, .needsApproval, .working, .finished, .ended])
        #expect(sessions[1].lastPrompt == "run the tests")
        #expect(sessions[2].tool == ToolCall(name: "run_shell_command", argument: "npm test"))
        #expect(sessions[3].detail == "Allow npm test?")
        #expect(sessions[5].detail == "All 12 tests pass.")
        #expect(sessions[0].id == "gemini:g1")
    }

    @Test func geminiFilePaths() throws {
        let p = try JSONDecoder().decode(HookPayload.self, from: Data(
            #"{"session_id":"g1","hook_event_name":"BeforeTool","tool_name":"read_file","tool_input":{"absolute_path":"/a/b.swift"}}"#.utf8))
        #expect(p.toolCall?.argument == "/a/b.swift")
    }

    /// What the plugin sends: already under Claude's names, so nothing is renamed.
    @Test func openCodeTurn() throws {
        let base = #""session_id":"ses_1","cwd":"/Users/dev/app""#
        let sessions = try replay([
            #"{\#(base),"hook_event_name":"SessionStart"}"#,
            #"{\#(base),"hook_event_name":"UserPromptSubmit","prompt":"fix the bug"}"#,
            #"{\#(base),"hook_event_name":"PreToolUse","tool_name":"edit","tool_input":{"filePath":"/Users/dev/app/a.ts"}}"#,
            #"{\#(base),"hook_event_name":"Notification","notification_type":"permission_prompt","message":"bash rm -rf build"}"#,
            #"{\#(base),"hook_event_name":"UserPromptSubmit"}"#,
            #"{\#(base),"hook_event_name":"Notification","notification_type":"elicitation_dialog","message":"Which file?"}"#,
            #"{\#(base),"hook_event_name":"Stop","last_assistant_message":"Fixed it."}"#,
            #"{\#(base),"hook_event_name":"Interrupt"}"#,
        ], source: .opencode)
        #expect(sessions.map(\.status) == [.idle, .working, .working, .needsApproval, .working, .needsInput, .finished, .idle])
        #expect(sessions[2].tool?.argument == "/Users/dev/app/a.ts")
        #expect(sessions[4].lastPrompt == "fix the bug") // an empty prompt keeps the title
        #expect(sessions[6].detail == "Fixed it.")
    }

    @Test func geminiEventNamesAreOnlyRenamedForGemini() {
        let p = HookPayload(sessionID: "s", hookEventName: "BeforeTool")
        #expect(p.normalized(for: .gemini).hookEventName == "PreToolUse")
        #expect(p.normalized(for: .claude).hookEventName == "BeforeTool")
    }
}

struct NewAgentInstallerTests {
    let home: URL
    let installer: HookInstaller

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".gemini"), withIntermediateDirectories: true)
        installer = HookInstaller(home: home, hookBinaryPath: "/Users/dev/.lookout/bin/lookout-hook")
    }

    @Test func geminiKeepsOtherSettingsAndUsesMilliseconds() throws {
        let existing = #"{"general":{"previewFeatures":true},"hooks":{"AfterAgent":[{"hooks":[{"type":"command","command":"other.sh"}]}]}}"#
        try existing.write(to: installer.geminiSettingsURL, atomically: true, encoding: .utf8)
        try installer.install(.gemini)
        let root = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: installer.geminiSettingsURL)) as? [String: Any])
        #expect((root["general"] as? [String: Any])?["previewFeatures"] as? Bool == true)
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookInstaller.geminiEvents))
        #expect(HookInstaller.commands(in: hooks["AfterAgent"]) == ["other.sh", "/Users/dev/.lookout/bin/lookout-hook gemini"])
        let entry = try #require(((hooks["BeforeTool"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])?.first)
        #expect(entry["timeout"] as? Int == 10_000)
        #expect(installer.isInstalled(.gemini))

        try installer.uninstall(.gemini)
        #expect(!installer.isInstalled(.gemini))
        let after = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: installer.geminiSettingsURL)) as? [String: Any])
        #expect(HookInstaller.commands(in: (after["hooks"] as? [String: Any])?["AfterAgent"]) == ["other.sh"])
    }

    @Test func openCodePlugin() throws {
        let url = OpenCodePlugin.url(home: home)
        #expect(!installer.isInstalled(.opencode))
        try installer.install(.opencode)
        let plugin = try String(contentsOf: url, encoding: .utf8)
        #expect(plugin.contains(#"const HOOK = "/Users/dev/.lookout/bin/lookout-hook";"#))
        #expect(plugin.hasPrefix("// \(HookInstaller.marker)"))
        #expect(installer.isInstalled(.opencode))
        #expect(installer.entryCount(.opencode) == 1)

        // An older plugin is rewritten on launch.
        try "// lookout-hook old\nconst HOOK = \"/Users/dev/.lookout/bin/lookout-hook\";".write(to: url, atomically: true, encoding: .utf8)
        installer.upgradeInstalled()
        #expect(try String(contentsOf: url, encoding: .utf8) == plugin)

        try installer.uninstall(.opencode)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
