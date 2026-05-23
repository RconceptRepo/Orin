import SwiftUI

struct TaskDraft: Identifiable {
    let id = UUID()
    var title = ""
    var description = ""
    var priority: TaskPriority = .p3Low
    var effortMinutes = 0
    var dueDate = Date()
    var hasDueDate = true
}

struct TaskEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var current = TaskDraft()
    @State private var pending: [TaskDraft] = []

    let title: String
    var defaultDueDate: Date? = Date()
    var onSave: ([TaskDraft]) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(title)
                .font(.title2.weight(.semibold))

            Form {
                TextField("Task title", text: $current.title)
                TextField("Description", text: $current.description, axis: .vertical)
                    .lineLimit(2...4)

                Picker("Priority", selection: $current.priority) {
                    ForEach(TaskPriority.allCases) { priority in
                        Text(priority.displayName).tag(priority)
                    }
                }

                Stepper("Effort: \(current.effortMinutes)m", value: $current.effortMinutes, in: 0...480, step: 15)
                Toggle("Due date", isOn: $current.hasDueDate)
                if current.hasDueDate {
                    DatePicker("Date", selection: $current.dueDate, displayedComponents: .date)
                }
            }
            .formStyle(.grouped)

            if !pending.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Pending Creations")
                        .font(.headline)
                    ForEach(pending) { draft in
                        HStack {
                            Circle()
                                .fill(PriorityStyle.color(for: draft.priority))
                                .frame(width: 7, height: 7)
                            Text(draft.title)
                            Spacer()
                            Text(draft.priority.displayName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            HStack {
                Button("Add Another Task") {
                    addCurrentToPending()
                }
                .disabled(current.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                Button("Save") {
                    addCurrentToPending()
                    onSave(pending)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(current.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && pending.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .frame(minHeight: 520)
        .onAppear {
            if let defaultDueDate {
                current.dueDate = defaultDueDate
                current.hasDueDate = true
            } else {
                current.hasDueDate = false
            }
        }
    }

    private func addCurrentToPending() {
        let trimmed = current.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        current.title = trimmed
        pending.append(current)
        current = TaskDraft(dueDate: current.dueDate, hasDueDate: current.hasDueDate)
    }
}
