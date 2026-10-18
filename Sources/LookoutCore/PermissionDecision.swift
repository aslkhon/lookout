import Foundation

/// The user's answer, from Lookout, to an agent asking permission for a tool call, or asking a question
/// (Claude's AskUserQuestion asks through the same permission request).
public enum PermissionDecision: Sendable, Equatable {
    case allow, deny
    /// Answers by question text: an option's label (labels joined by ", " for several), or the user's own words.
    case answer([String: String])
    /// A deny that tells the agent what to change; for a plan, "Tell Claude what to change".
    case feedback(String)

    public var isAnswer: Bool {
        if case .answer = self { true } else { false }
    }

    /// How it travels to the waiting hook: "allow", "deny", or "answer" and a JSON object on the next line.
    public var wire: String {
        switch self {
        case .allow: "allow"
        case .deny: "deny"
        case .feedback(let text): "feedback\n" + text
        case .answer(let answers):
            "answer\n" + String(decoding: (try? JSONSerialization.data(withJSONObject: answers, options: .sortedKeys)) ?? Data("{}".utf8), as: UTF8.self)
        }
    }

    public init?(wire: String) {
        let (head, rest) = wire.firstIndex(of: "\n").map { (wire[..<$0], wire[wire.index(after: $0)...]) } ?? (wire[...], "")
        switch head {
        case "allow": self = .allow
        case "deny": self = .deny
        case "feedback":
            let text = rest.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            self = .feedback(text)
        case "answer":
            guard let answers = try? JSONSerialization.jsonObject(with: Data(rest.utf8)) as? [String: String] else { return nil }
            self = .answer(answers)
        default: return nil
        }
    }

    /// A remote hook's request id, which Lookout puts in a shell command: 32 hex digits, nothing else.
    public static func isValidRequestID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// What the waiting `lookout-hook` prints for Claude Code. Its terminal dialog closes either way.
    /// `toolInput` is the request's full input: answers go back as an allow with it plus `answers`.
    public func hookOutput(toolInput: [String: Any] = [:]) -> Data {
        var decision: [String: Any]
        switch self {
        case .allow: decision = ["behavior": "allow"]
        case .deny: decision = ["behavior": "deny", "message": "Denied from Lookout"]
        case .feedback(let text): decision = ["behavior": "deny", "message": text]
        case .answer(let answers):
            var input = toolInput
            input["answers"] = answers
            decision = ["behavior": "allow", "updatedInput": input]
        }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output, options: .sortedKeys)) ?? Data()
    }
}

/// Claude's plan, when it asks to leave plan mode. A hook can't approve one (Claude ignores the allow), only
/// send feedback; approving happens in the terminal.
public enum PlanReview {
    public static let tool = "ExitPlanMode"
    /// Plans are kept whole by the hooks up to this size.
    public static let maxLength = 64 << 10

    public static func plan(_ toolInput: [String: JSONValue]?, tool: String?) -> String? {
        guard tool == Self.tool, case .string(let plan)? = toolInput?["plan"], !plan.isEmpty else { return nil }
        return plan
    }
}

/// One question from Claude's AskUserQuestion tool.
public struct AgentQuestion: Equatable, Sendable {
    public struct Option: Equatable, Sendable {
        public var label: String
        public var description: String?
    }

    public var text: String
    public var header: String?
    public var options: [Option]
    public var multiSelect: Bool

    /// The only tool whose permission request takes answers: an answer allows the call with changed input.
    public static let tool = "AskUserQuestion"

    /// The questions in an AskUserQuestion tool input; none for any other tool.
    public static func parse(_ toolInput: [String: JSONValue]?, tool: String?) -> [AgentQuestion] {
        guard tool == Self.tool, case .array(let items)? = toolInput?["questions"] else { return [] }
        return items.compactMap { item in
            guard case .object(let q) = item, case .string(let text)? = q["question"] else { return nil }
            var options: [Option] = []
            if case .array(let list)? = q["options"] {
                for case .object(let o) in list {
                    guard case .string(let label)? = o["label"] else { continue }
                    var description: String?
                    if case .string(let d)? = o["description"] { description = d }
                    options.append(Option(label: label, description: description))
                }
            }
            var header: String?
            if case .string(let h)? = q["header"] { header = h }
            return AgentQuestion(text: text, header: header, options: options, multiSelect: q["multiSelect"] == .bool(true))
        }
    }
}
