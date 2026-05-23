import SwiftUI

struct TaskRowView: View {
    let task: TaskItem
    var showsDescription = false
    var onToggleComplete: (() -> Void)?

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

            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .frame(height: 56)
        .padding(.horizontal, 14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.clear)
        }
        .accessibilityElement(children: .combine)
    }
}
