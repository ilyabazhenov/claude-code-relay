import Foundation

/// Matches tool commands against the configured "dangerous command" rules.
///
/// A rule matches if the command contains it (case-insensitive substring). This is
/// deliberately simple and conservative — false positives just mean the user is
/// asked to confirm, which is the safe direction.
enum DangerRules {
    /// Returns the first rule that matches `command`, or nil if none do.
    static func firstMatch(command: String, rules: [String]) -> String? {
        let haystack = command.lowercased()
        for rule in rules {
            let needle = rule.lowercased()
            guard !needle.isEmpty else { continue }
            if haystack.contains(needle) {
                return rule
            }
        }
        return nil
    }
}
