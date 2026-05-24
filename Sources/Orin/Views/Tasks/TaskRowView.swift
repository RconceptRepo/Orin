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

    var body: some View {
        HStack(spacing: 12) {
            Button {
                onToggleComplete?()
            } label: {
                Image(systemName: task.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(task.status == .completed ? OrinColor.success : OrinColor.p3)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(OrinFont.body.weight(.medium))
                    .strikethrough(task.status == .completed)

                if showsDescription, !task.taskDescription.isEmpty {
                    Text(task.taskDescription)
                        .font(OrinFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if !task.subtasks.isEmpty {
                    let done = task.subtasks.filter { $0.isCompleted }.count
                    HStack(spacing: 4) {
                        Image(systemName: "list.bullet").font(.system(size: 10))
                        Text("\(done)/\(task.subtasks.count) subtasks").font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
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
                        Button("Edit") { onEdit() }
                    }
                    if let onBreakIntoSubtasks {
                        Button("Break Into Subtasks") { onBreakIntoSubtasks() }
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
        .frame(height: 56)
        .padding(.horizontal, 14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear)
        }
        .accessibilityElement(children: .combine)
    }

    private var hasMenuActions: Bool {
        onEdit != nil || onDelete != nil || onBreakIntoSubtasks != nil || onActivate != nil || onReactivate != nil
    }
}
