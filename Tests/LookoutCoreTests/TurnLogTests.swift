import Foundation
import Testing
@testable import LookoutCore

struct TurnLogTests {
    @Test func appendLoadAndSum() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turns-\(UUID()).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        TurnLog.append(TurnRecord(end: now - 3 * 86400, project: "old", source: .claude, host: nil, duration: 999), to: url)
        TurnLog.append(TurnRecord(end: now - 60, project: "webshop", source: .claude, host: nil, duration: 120), to: url)
        TurnLog.append(TurnRecord(end: now - 30, project: "api", source: .codex, host: "build-box", duration: 600), to: url)
        TurnLog.append(TurnRecord(end: now, project: "webshop", source: .codex, host: nil, duration: 60), to: url)
        try FileHandle(forWritingTo: url).write(contentsOf: Data("garbage\n".utf8)) // overwrites the start: one bad line

        let recent = TurnLog.load(from: url, since: now - 86400)
        #expect(recent.count == 3)
        #expect(recent.last?.host == nil && recent[1].host == "build-box")
        #expect(TurnLog.byProject(recent) == [
            ProjectUsage(project: "api", turns: 1, time: 600),
            ProjectUsage(project: "webshop", turns: 2, time: 180),
        ])
        #expect(TurnLog.byProject(recent)[1].averageTurn == 90)
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int == 0o600)
    }
}
