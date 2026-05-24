import SwiftData
import SwiftUI

struct TaskRowView: View {
    let task: TaskItem
    var showsDescription = false
    var onToggleComplete: (() -> Void)?
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onBreakIntoSubtasks: (() -> Void)?
    var onActivate: (() -> Void)?
    var onReactivate: (() -> Void)?

    @State private var isSubtasksExpanded = false
    @Environment(\.modelContext) private var modelContext

    private var sortedSubtasks: [SubTaskItem] {
        task.subtasks.sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            mainRow
                .padding(.horizontal, 14)

            if isSubtasksExpanded && !task.subtasks.isEmpty {
                subtaskExpansion
                    .padding(.horizontal, 14)
                    .padding(.leading, 26)
                    .padding(.bottom, 8)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear)
        }
        .accessibilityElement(children: .contain)
        .animation(.easeInOut(duration: 0.15), value: isSubtasksExpanded)
    }

    // MARK: - Main row

    private var mainRow: some View {
        HStack(spacing: 12) {
            Button {
                onToggleComplete?()
            } label: {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(task.status == .completed ? OrinColor.success : OrinColor.p3)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(task.status == .completed ? "Mark incomplete" : "Mark complete")

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(OrinFont.body.weight(.medium))
                    .strikethrough(task.status == .completed)
                    .accessibilityLabel(task.title)

                if showsDescription, !task.taskDescription.isEmpty {
                    Text(task.taskDescription)
                        .font(OrinFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !task.subtasks.isEmpty {
                    let done = task.subtasks.filter(\.isCompleted).count
                    let total = task.subtasks.count
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isSubtasksExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: isSubtasksExpanded ? "chevron.up" : "list.bullet")
                                .font(.system(size: 9))
                            Text("\(done)/\(total) subtasks")
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(done) of \(total) subtasks complete. \(isSubtasksExpanded ? "Collapse" : "Expand")")
                }
            }

            Spacer()

            PriorityBadge(priority: task.priority)

            if let dueDate = task.dueDate {
                Text(dueDate.formatted(date: .abbreviated, time: .omitted))
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 70, alignment: .trailing)
            }

            if task.effortEstimateMinutes > 0 {
                Text("\(task.effortEstimateMinutes)m")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            }

            if hasMenuActions {
                Menu {
                    if let onEdit {
                        Button("Edit Task") { onEdit() }
                    }
                    if let onBreakIntoSubtasks {
                        Button("Manage Subtasks") { onBreakIntoSubtasks() }
                    }
                    if let onActivate {
                        Button("Activate Today") { onActivate() }
                    }
                    if let onReactivate {
                        Button("Reactivate") { onReactivate() }
                    }
                    if task.status == .active, let onToggleComplete {
                        Button("Mark Complete") { onToggleComplete() }
                    }
                    if let onDelete {
                        Divider()
                        Button("Delete", role: .destructive) { onDelete() }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Color.clear.frame(width: 28, height: 28)
            }
        }
        .frame(minHeight: 56)
    }

    // MARK: - Inline subtask expansion

    private var subtaskExpansion: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(sortedSubtasks) { subtask in
                SubtaskCompactRow(subtask: subtask) {
                    try? modelContext.save()
                }
            }
        }
    }

    private var hasMenuActions: Bool {
        onEdit != nil || onDelete != nil || onBreakIntoSubtasks != nil || onActivate != nil || onReactivate != nil
    }
}
