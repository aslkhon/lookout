import Foundation

/// The user's answer, from Lookout, to an agent asking permission for a tool call.
public enum PermissionDecision: String, Sendable {
    case allow, deny

    /// What the waiting `lookout-hook` prints for Claude Code. Its terminal dialog closes either way.
    public var hookOutput: Data {
        var decision: [String: Any] = ["behavior": rawValue]
        if self == .deny { decision["message"] = "Denied from Lookout" }
        let output = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        return (try? JSONSerialization.data(withJSONObject: output, options: .sortedKeys)) ?? Data()
    }
}
