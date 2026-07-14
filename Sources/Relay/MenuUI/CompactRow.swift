import SwiftUI

/// Compact one-liner for a monitored session (active or recently ended).
struct CompactRow: View {
    let session: Session
    let onFocus: () -> Void
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        Button(action: onFocus) {
            HStack(spacing: 8) {
                Circle().fill(session.state.dotColor).frame(width: 7, height: 7)
                Text(session.projectName).font(.caption).lineLimit(1).layoutPriority(1)
                if let branch = session.gitBranch {
                    BranchChip(branch: branch)
                }
                if let task = session.taskTitle {
                    Text("· \(task)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                if !session.hasTmux {
                    Image(systemName: "macwindow").font(.system(size: 9)).foregroundStyle(.tertiary)
                }
                Text(session.state.label(loc)).font(.caption2).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(session.hasTmux ? loc.focusTerminal : loc.openInDesktopApp)
        .padding(.leading, 14)
        .padding(.vertical, 1)
    }
}

/// A small git-branch pill.
struct BranchChip: View {
    let branch: String
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8))
            Text(branch).font(.system(size: 10)).lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 5).padding(.vertical, 1)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}
