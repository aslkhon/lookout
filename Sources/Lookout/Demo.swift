import Foundation
import LookoutCore

/// Made-up agents for screenshots: launch with `-demo YES` (see scripts/screenshots.sh). Nothing is monitored meanwhile.
enum Demo {
    static var isOn: Bool { UserDefaults.standard.bool(forKey: "demo") }

    static func sessions(now: Date = Date()) -> [AgentSession] {
        [
            make(.claude, "webshop", .needsApproval, ago: 40, name: "Checkout refactor", branch: "checkout-v2",
                 detail: "Bash: npm run db:migrate", app: "com.mitchellh.ghostty"),
            make(.codex, "webshop", .working, ago: 95, name: "Cart unit tests", detail: "Edit: cart.test.ts",
                 app: "com.microsoft.VSCode"),
            make(.claude, "api-gateway", .working, ago: 300, name: "Rate limiting", detail: "Bash: go test ./...",
                 host: "build-box"),
            make(.claude, "api-gateway", .finished, ago: 120, name: "Fix CORS headers", host: "build-box"),
            make(.codex, "mobile-app", .needsInput, ago: 15, name: "Onboarding screens",
                 detail: "Which icon set should I use?", app: "com.mitchellh.ghostty"),
            make(.claude, "mobile-app", .idle, ago: 2400, name: "Dark mode", app: "com.microsoft.VSCode"),
            make(.codex, "ml-pipeline", .working, ago: 1800, name: "Retrain ranking model",
                 detail: "Bash: python train.py --epochs 20", host: "gpu-box"),
            make(.claude, "docs", .idle, ago: 7200, name: "Update API reference", app: "com.apple.Terminal"),
        ].map { s in var s = s; s.statusSince = now - s.statusSince.timeIntervalSince1970; return s }
    }

    private static var counter = 0

    /// `statusSince` holds the age in seconds until `sessions` turns it into a date.
    private static func make(_ source: AgentSource, _ project: String, _ status: AgentStatus, ago: TimeInterval,
                             name: String, branch: String = "main", detail: String? = nil,
                             host: String? = nil, app: String? = nil) -> AgentSession {
        counter += 1
        let cwd = host == nil ? NSHomeDirectory() + "/Developer/\(project)" : "/home/me/\(project)"
        let json = #"{"session_id":"demo-\#(counter)","hook_event_name":"SessionStart","cwd":"\#(cwd)"}"#
        let payload = try! JSONDecoder().decode(HookPayload.self, from: Data(json.utf8))
        var s = SessionReducer.apply(HookEnvelope(source: source, context: HookContext(), payload: payload, host: host), to: nil)
        s.status = status
        s.statusSince = Date(timeIntervalSince1970: ago)
        s.name = name
        s.branch = branch
        s.detail = detail
        s.hostBundleID = app
        s.startedAt = Date() - ago - 600
        if status == .finished { s.lastTurnDuration = 260 }
        return s
    }
}
