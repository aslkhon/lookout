import Foundation
import Testing
@testable import LookoutCore

struct SessionReducerTests {
    func fixture(_ name: String) throws -> [HookPayload] {
        let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "jsonl"))
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(HookPayload.self, from: Data($0.utf8)) }
    }

    /// Replays payloads; returns the status after each one and which ones triggered a notification.
    func replay(_ payloads: [HookPayload], source: AgentSource) -> (statuses: [AgentStatus], notified: [AgentStatus], last: AgentSession?) {
        var session: AgentSession?
        var statuses: [AgentStatus] = []
        var notified: [AgentStatus] = []
        for p in payloads {
            let env = HookEnvelope(source: source, context: HookContext(agentPID: 42, hostBundleID: "com.mitchellh.ghostty"), payload: p)
            let next = SessionReducer.apply(env, to: session)
            if SessionReducer.shouldNotify(from: session?.status, to: next.status) { notified.append(next.status) }
            session = next
            statuses.append(next.status)
        }
        return (statuses, notified, session)
    }

    func payload(_ event: String, tool: String? = nil, input: [String: JSONValue]? = nil,
                 notification: String? = nil, message: String? = nil) -> HookPayload {
        HookPayload(sessionID: "s1", hookEventName: event, cwd: "/Users/dev/project", toolName: tool,
                    toolInput: input, notificationType: notification, message: message)
    }

    @Test func questionsAskedThroughPermissionRequestStayNeedsInput() {
        let input: [String: JSONValue] = ["questions": .array([.object(["question": .string("Which color?")])])]
        let result = replay([payload("PreToolUse", tool: "AskUserQuestion", input: input),
                             payload("PermissionRequest", tool: "AskUserQuestion", input: input)], source: .claude)
        #expect(result.statuses == [.needsInput, .needsInput])
        #expect(result.last?.detail == "Which color?")
    }

    @Test func planReviewNeedsApproval() {
        let input: [String: JSONValue] = ["plan": .string("# Plan")]
        let result = replay([payload("PermissionRequest", tool: "ExitPlanMode", input: input)], source: .claude)
        #expect(result.statuses == [.needsApproval])
        #expect(result.last?.detail == "Plan ready for review")
        #expect(result.last?.tool?.name == "ExitPlanMode")
    }

    @Test func stallsAfterTenQuietMinutesWhileWorking() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        func env(_ p: HookPayload) -> HookEnvelope { HookEnvelope(source: .claude, context: HookContext(), payload: p) }
        var s = SessionReducer.apply(env(payload("PreToolUse", tool: "Bash", input: ["command": .string("npm test")])), to: nil, now: start)
        #expect(!SessionReducer.isStalled(s, now: start + 9 * 60))
        #expect(SessionReducer.isStalled(s, now: start + 10 * 60))
        s.stalled = true
        s = SessionReducer.apply(env(payload("PostToolUse", tool: "Bash")), to: s, now: start + 11 * 60)
        #expect(!s.stalled) // any event clears it
        #expect(!SessionReducer.isStalled(s, now: start + 12 * 60))
        s = SessionReducer.apply(env(payload("Stop")), to: s, now: start + 12 * 60)
        #expect(!SessionReducer.isStalled(s, now: start + 60 * 60)) // only working agents stall
    }

    @Test(arguments: [("claude-turn", AgentSource.claude), ("codex-turn", .codex)])
    func recordedTurn(name: String, source: AgentSource) throws {
        let result = replay(try fixture(name), source: source)
        #expect(result.statuses == [.idle, .working, .working, .working, .finished, .ended])
        #expect(result.notified == [.finished])
        #expect(result.last?.projectName == "project")
        #expect(result.last?.lastPrompt?.contains("echo hi") == true)
        #expect(result.last?.agentPID == 42)
    }

    @Test func recordedToolDetail() throws {
        let events = try fixture("codex-turn")
        let result = replay(Array(events.prefix(3)), source: .codex)
        #expect(result.last?.detail == "Bash: echo hi")
    }

    @Test func approvalFlow() {
        let result = replay([
            payload("UserPromptSubmit"),
            payload("PermissionRequest", tool: "Bash", input: ["command": .string("rm -rf build")]),
            payload("Notification", notification: "permission_prompt", message: "Claude needs your permission to use Bash"),
            payload("PostToolUse", tool: "Bash", input: ["command": .string("rm -rf build")]),
            payload("Stop"),
        ], source: .claude)
        #expect(result.statuses == [.working, .needsApproval, .needsApproval, .working, .finished])
        #expect(result.notified == [.needsApproval, .finished])
    }

    @Test func permissionDetailSurvivesNotification() {
        let result = replay([
            payload("PermissionRequest", tool: "Bash", input: ["command": .string("npm test")]),
            payload("Notification", notification: "permission_prompt", message: "generic"),
        ], source: .claude)
        #expect(result.last?.detail == "Bash: npm test")
    }

    @Test func askUserQuestionNeedsInput() {
        let question: JSONValue = .array([.object(["question": .string("Which database?")])])
        let result = replay([
            payload("UserPromptSubmit"),
            payload("PreToolUse", tool: "AskUserQuestion", input: ["questions": question]),
        ], source: .claude)
        #expect(result.last?.status == .needsInput)
        #expect(result.last?.detail == "Which database?")
        #expect(result.notified == [.needsInput])
    }

    @Test func idlePromptFinishesOnlyWorkingSessions() {
        let fromWorking = replay([payload("UserPromptSubmit"), payload("Notification", notification: "idle_prompt")], source: .claude)
        #expect(fromWorking.last?.status == .finished)

        let fromFinished = replay([payload("Stop"), payload("Notification", notification: "idle_prompt")], source: .claude)
        #expect(fromFinished.notified == [.finished]) // no second notification
    }

    @Test func interruptGoesIdleWithoutNotification() {
        let result = replay([payload("UserPromptSubmit"), payload("Interrupt")], source: .codex)
        #expect(result.last?.status == .idle)
        #expect(result.notified.isEmpty)
    }

    @Test func unknownEventsKeepStatus() {
        let result = replay([payload("UserPromptSubmit"), payload("PreCompact"), payload("SubagentStop")], source: .claude)
        #expect(result.statuses == [.working, .working, .working])
    }
}
