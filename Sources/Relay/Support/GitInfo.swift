import Foundation

/// Reads the current git branch for a working directory by parsing `.git/HEAD`
/// directly (no `git` process, no dependency). Handles worktrees, where `.git` is a
/// file pointing at the real gitdir.
enum GitInfo {
    static func branch(cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        guard let gitDir = resolveGitDir(cwd: cwd) else { return nil }

        let headPath = (gitDir as NSString).appendingPathComponent("HEAD")
        guard let head = try? String(contentsOfFile: headPath, encoding: .utf8) else { return nil }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)

        if trimmed.hasPrefix("ref:") {
            // "ref: refs/heads/feature/foo" → "feature/foo"
            let ref = trimmed.dropFirst(4).trimmingCharacters(in: .whitespaces)
            return ref.components(separatedBy: "refs/heads/").last ?? ref
        }
        // Detached HEAD: show a short hash.
        return trimmed.count >= 7 ? String(trimmed.prefix(7)) : trimmed
    }

    /// Walks up from `cwd` to find a `.git` directory (or worktree pointer file).
    private static func resolveGitDir(cwd: String) -> String? {
        let fm = FileManager.default
        var dir = cwd
        for _ in 0..<25 {   // bounded walk toward the filesystem root
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dotGit, isDirectory: &isDir) {
                if isDir.boolValue {
                    return dotGit
                }
                // Worktree: `.git` is a file "gitdir: /abs/path/to/gitdir".
                if let contents = try? String(contentsOfFile: dotGit, encoding: .utf8) {
                    let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                    if line.hasPrefix("gitdir:") {
                        return String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
                    }
                }
                return nil
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir { break }
            dir = parent
        }
        return nil
    }
}
