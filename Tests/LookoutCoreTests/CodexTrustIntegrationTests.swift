import Foundation
import Testing
@testable import LookoutCore

/// Talks to the real `codex` install. Opt in with LOOKOUT_INTEGRATION=1; run it under a
/// GUI-like environment to check PATH handling:
///   env -i HOME=$HOME PATH=/usr/bin:/bin LOOKOUT_INTEGRATION=1 swift test --filter CodexTrustIntegration
@Suite(.enabled(if: ProcessInfo.processInfo.environment["LOOKOUT_INTEGRATION"] == "1"))
struct CodexTrustIntegrationTests {
    @Test func appServerStartsWithLoginShellPath() throws {
        let path = CodexTrust.shellPath()
        let codex = try #require(CodexTrust.findCodex(path: path))
        // Only lists hooks and trusts untrusted Lookout ones; already-trusted hooks are left alone.
        let hooksFile = HookInstaller().codexHooksURL.path
        _ = try CodexTrust.trustLookoutHooks(hooksFile: hooksFile, codexPath: codex, path: path)
    }
}
