import Foundation
import Testing
@testable import LookoutCore

struct TranscriptTests {
    private func lines(_ json: String...) -> [Data] { json.map { Data($0.utf8) } }

    @Test func claudePromptsRepliesAndTools() {
        let entries = Transcript.parse(lines(
            #"{"type":"user","timestamp":"2026-10-16T10:00:00.000Z","message":{"role":"user","content":"fix the tests"}}"#,
            #"{"type":"user","isMeta":true,"message":{"role":"user","content":"meta"}}"#,
            #"{"type":"user","message":{"role":"user","content":"<command-name>/clear</command-name>"}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hm"},{"type":"text","text":"On it."}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}"#,
            #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"subagent"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a/b/App.swift"}}]}}"#,
            #"not json"#
        ), source: .claude)
        #expect(entries.map(\.kind) == [.user, .assistant, .tool, .tool])
        #expect(entries.map(\.text) == ["fix the tests", "On it.", "Bash: swift test", "Read: App.swift"])
        #expect(entries.first?.date != nil)
    }

    @Test func codexItemsAndOlderEvents() {
        let entries = Transcript.parse(lines(
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"UserMessage","content":[{"type":"text","text":"is prod up?"}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"Reasoning"}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"CommandExecution","command":["/bin/zsh","-lc","curl x"],"parsed_cmd":[{"cmd":"curl x"}]}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"FileChange","changes":{"/r/b.py":{},"/r/a.py":{}}}}}"#,
            #"{"type":"event_msg","payload":{"type":"item_completed","item":{"type":"AgentMessage","content":[{"type":"Text","text":"Yes."}]}}}"#,
            #"{"type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"AGENTS.md instructions"}]}}"#,
            #"{"type":"event_msg","payload":{"type":"user_message","message":"old prompt"}}"#
        ), source: .codex)
        #expect(entries.map(\.text) == ["is prod up?", "Bash: curl x", "Edit: a.py, b.py", "Yes.", "old prompt"])
    }

    @Test func remoteOutput() {
        let output = Data((#"120"# + "\t" + #"{"type":"user","message":{"role":"user","content":"deploy"}}"# + "\n"
            + "not a line\n"
            + "\(Int.max)\t" + #"{"type":"user","message":{"role":"user","content":"overflow"}}"# + "\n"
            + "-5\t" + #"{"type":"user","message":{"role":"user","content":"negative"}}"# + "\n"
            + #"300"# + "\t" + #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Done."},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"# + "\n").utf8)
        let entries = Transcript.parseRemote(output, source: .claude)
        #expect(entries.map(\.text) == ["deploy", "Done.", "Bash: ls"])
        #expect(entries.map(\.id) == [120 * 64, 300 * 64, 300 * 64 + 1])
        #expect(Transcript.parseRemote(output, source: .claude, limit: 1).map(\.text) == ["Bash: ls"])
    }

    @Test func loadReadsOnlyTheTail() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let body = (1...200).map { #"{"type":"user","message":{"role":"user","content":"prompt \#($0)"}}"# }.joined(separator: "\n")
        try body.write(to: url, atomically: true, encoding: .utf8)
        let entries = Transcript.load(url, source: .claude, limit: 5, chunk: 100) // lines straddle chunks
        #expect(entries.map(\.text) == (196...200).map { "prompt \($0)" })
        #expect(Transcript.load(url, source: .claude, limit: 500, chunk: 100).count == 200)
        #expect(Transcript.load(url, source: .claude, limit: 5, maxLine: 10).isEmpty) // every line too long

        // Ids don't shift when the file grows.
        let before = Transcript.load(url, source: .claude, limit: 5, chunk: 100)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"prompt 201\"}}".utf8))
        try handle.close()
        let after = Transcript.load(url, source: .claude, limit: 5, chunk: 100)
        #expect(after.map(\.text).last == "prompt 201")
        #expect(Array(before.dropFirst()) == Array(after.dropLast()))
    }
}
