import Foundation

/// What agents did while the user was away: "2 finished · 1 needs you — webshop, docs".
public enum AwaySummary {
    /// Nil when nothing worth telling happened since `since`.
    public static func text(for sessions: [AgentSession], since: Date) -> String? {
        let changed = sessions.filter { s in
            s.stalled || (s.statusSince >= since && (s.status == .finished || s.status.needsAttention))
        }
        guard !changed.isEmpty else { return nil }
        let counts: [(Int, String)] = [
            (changed.filter { $0.status == .finished }.count, "finished"),
            (changed.filter(\.status.needsAttention).count, "needs you"),
            (changed.filter(\.stalled).count, "went quiet"),
        ]
        let parts = counts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        var projects: [String] = []
        for s in changed.sorted(by: { $0.status.rank < $1.status.rank }) where !projects.contains(s.projectName) {
            projects.append(s.projectName)
        }
        return parts.joined(separator: " · ") + " — " + projects.joined(separator: ", ")
    }
}
