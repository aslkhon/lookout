import Foundation

public enum GitInfo {
    /// Current branch of the repository containing `directory` (short commit when detached), read
    /// straight from `.git/HEAD` so it's cheap enough to poll. Handles worktrees, whose `.git` is a file.
    public static func branch(of directory: String) -> String? {
        var dir = URL(fileURLWithPath: directory)
        for _ in 0..<32 {
            let dotGit = dir.appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let text = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = text.split(separator: "\n").first, line.hasPrefix("gitdir:") else { return nil }
                    let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = URL(fileURLWithPath: path, relativeTo: dir)
                }
                guard let head = try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8) else { return nil }
                return branch(head: head)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { return nil }
            dir = parent
        }
        return nil
    }

    static func branch(head: String) -> String? {
        let head = head.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst("ref: refs/heads/".count)) }
        return head.count >= 7 ? String(head.prefix(7)) : nil
    }
}
