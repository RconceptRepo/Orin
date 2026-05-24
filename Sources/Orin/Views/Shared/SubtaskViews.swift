import SwiftData
import SwiftUI

// MARK: - SubtaskEditRow
// Full-featured row: toggle complete, single-click to rename, delete button.
// Used inside the List-based edit sheets (TaskEditSheet, TodayTaskEditSheet).

struct SubtaskEditRow: View {
    @Bindable var subtask: SubTaskItem
    var onDelete: () -> Void
    var onChange: () -> Void

    @State private var isEditing = false
    @State private var editTitle = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Button {
                subtask.isCompleted.toggle()
                onChange()
            } label: {
                Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(subtask.isCompleted ? OrinColor.success : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(subtask.isCompleted ? "Mark incomplete" : "Mark complete")

            if isEditing {
                TextField("Subtask title", text: $editTitle)
                    .focused($titleFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { isEditing = false }
                    .onAppear {
                        editTitle = subtask.title
                        titleFocused = true
                    }
            } else {
                Text(subtask.title)
                    .font(OrinFont.body)
                    .strikethrough(subtask.isCompleted)
                    .foregroundStyle(subtask.isCompleted ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { isEditing = true }
                    .accessibilityHint("Tap to rename")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(OrinColor.error.opacity(0.7))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Delete subtask")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
    }

    private func commitEdit() {
        let trimmed = editTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            subtask.title = trimmed
            onChange()
        }
        isEditing = false
    }
}

// MARK: - SubtaskCompactRow
// Toggle-only row for inline display in TaskRowView expanded section.

struct SubtaskCompactRow: View {
    @Bindable var subtask: SubTaskItem
    var onChange: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button {
                subtask.isCompleted.toggle()
                onChange()
            } label: {
                Image(systemName: subtask.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(subtask.isCompleted ? OrinColor.success : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(subtask.isCompleted ? "Mark incomplete" : "Mark complete")

            Text(subtask.title)
                .font(.system(size: 12))
                .strikethrough(subtask.isCompleted)
                .foregroundStyle(subtask.isCompleted ? .secondary : .primary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(subtask.title), \(subtask.isCompleted ? "completed" : "active")")
    }
}
