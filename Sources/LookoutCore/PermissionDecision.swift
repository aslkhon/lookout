import Foundation

/// The user's answer, from Lookout, to an agent asking permission for a tool call.
public enum PermissionDecision: String, Sendable {
    case allow, deny

    /// A remote hook's request id, which Lookout puts in a shell command: 32 hex digits, nothing else.
    public static func isValidRequestID(_ id: String) -> Bool {
        id.utf8.count == 32 && id.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    /// What the waiting `lookout-hook` prints for Claude Code. Its terminal dialog closes either way.
    public var hookOutput: Data {
        var decision: [String: Any] = ["behavior": rawValue]
        if self == .deny { decision["message"] = "Denied from Lookout" }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output, options: .sortedKeys)) ?? Data()
    }
}
