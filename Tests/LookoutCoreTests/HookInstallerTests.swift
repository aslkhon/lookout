import Foundation
import Testing
@testable import LookoutCore

struct HookInstallerTests {
    let home: URL
    let installer: HookInstaller

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("lookout-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        installer = HookInstaller(home: home, hookBinaryPath: "/Users/dev/.lookout/bin/lookout-hook")
    }

    func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    let existingSettings = """
    {
      "model": "opus",
      "hooks": {
        "Stop": [{"hooks": [{"type": "command", "command": "afplay done.aiff"}]}],
        "PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "guard.sh"}]}]
      }
    }
    """

    @Test func installPreservesExistingHooksAndSettings() throws {
        try existingSettings.write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)
        try installer.install(.claude)

        let root = try readJSON(installer.claudeSettingsURL)
        #expect(root["model"] as? String == "opus")
        let hooks = try #require(root["hooks"] as? [String: Any])
        #expect(HookInstaller.commands(in: hooks["Stop"]) == ["afplay done.aiff", "/Users/dev/.lookout/bin/lookout-hook claude"])
        #expect(HookInstaller.commands(in: hooks["PreToolUse"]) == ["guard.sh", "/Users/dev/.lookout/bin/lookout-hook claude"])
        #expect(installer.isInstalled(.claude))

        let backups = try FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent(".claude").path)
            .filter { $0.hasPrefix("settings.json.lookout-backup-") }
        #expect(backups.count == 1)
    }

    @Test func installIsIdempotent() throws {
        try installer.install(.claude)
        try installer.install(.claude)
        let hooks = try #require(try readJSON(installer.claudeSettingsURL)["hooks"] as? [String: Any])
        for event in HookInstaller.claudeEvents {
            #expect(HookInstaller.commands(in: hooks[event]).count == 1, "\(event)")
        }
    }

    @Test func uninstallRestoresOriginalHooks() throws {
        try existingSettings.write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)
        let original = try readJSON(installer.claudeSettingsURL)
        try installer.install(.claude)
        try installer.uninstall(.claude)
        let after = try readJSON(installer.claudeSettingsURL)
        #expect(NSDictionary(dictionary: after).isEqual(to: original))
        #expect(!installer.isInstalled(.claude))
    }

    @Test func codexInstallCreatesHooksFile() throws {
        try installer.install(.codex)
        let hooks = try #require(try readJSON(installer.codexHooksURL)["hooks"] as? [String: Any])
        #expect(Set(hooks.keys) == Set(HookInstaller.codexEvents))
        #expect(HookInstaller.commands(in: hooks["Stop"]) == ["/Users/dev/.lookout/bin/lookout-hook codex"])
        // Codex groups carry no matcher (applies to all tools).
        let group = try #require((hooks["PreToolUse"] as? [[String: Any]])?.first)
        #expect(group["matcher"] == nil)

        try installer.uninstall(.codex)
        #expect(try readJSON(installer.codexHooksURL)["hooks"] == nil)
    }

    @Test func refusesToOverwriteInvalidJSON() throws {
        try "{ not json".write(to: installer.claudeSettingsURL, atomically: true, encoding: .utf8)
        #expect(throws: InstallerError.self) { try installer.install(.claude) }
        #expect(try String(contentsOf: installer.claudeSettingsURL, encoding: .utf8) == "{ not json")
    }
}
