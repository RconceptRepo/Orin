import SwiftData
import SwiftUI

struct AllTasksView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<TaskItem> { !$0.isBacklog },
        sort: \TaskItem.createdAt,
        order: .reverse
    )
    private var tasks: [TaskItem]

    @State private var taskToEdit: TaskItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("All Tasks")
                .font(.title2.weight(.semibold))

            List {
                ForEach(tasks) { task in
                    TaskRowView(task: task, showsDescription: true)
                        .contextMenu {
                            if task.status == .active {
                                Button("Complete") { complete(task) }
                                Button("Edit") { taskToEdit = task }
                                Button("Break Into Subtasks") { addDefaultSubtasks(to: task) }
                            } else {
                                Button("Reactivate") { reactivate(task) }
                            }
                            Button("Delete", role: .destructive) { delete(task) }
                        }
                }
            }
        }
        .padding()
        .sheet(item: $taskToEdit) { task in
            TaskEditSheet(task: task) {
                try? modelContext.save()
                taskToEdit = nil
            }
        }
    }

    private func complete(_ task: TaskItem) {
        task.status = .completed
        task.completedAt = Date()
        try? modelContext.save()
    }

    private func reactivate(_ task: TaskItem) {
        task.status = .active
        task.completedAt = nil
        try? modelContext.save()
    }

    private func delete(_ task: TaskItem) {
        modelContext.delete(task)
        try? modelContext.save()
    }

    private func addDefaultSubtasks(to task: TaskItem) {
        guard task.subtasks.isEmpty else { return }
        task.subtasks = [
            SubTaskItem(title: "Clarify outcome"),
            SubTaskItem(title: "Do first pass"),
            SubTaskItem(title: "Review and send")
        ]
        try? modelContext.save()
    }
}

// MARK: - Edit sheet

private struct TaskEditSheet: View {
    @Bindable var task: TaskItem
    var onSave: () -> Void

    @State private var title: String = ""
    @State private var description: String = ""
    @State private var priority: TaskPriority = .p3Low
    @State private var effortMinutes: Int = 0
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Edit Task")
                .font(.title2.weight(.semibold))

            Form {
                TextField("Task title", text: $title)
                TextField("Description", text: $description, axis: .vertical)
                    .lineLimit(2...4)

                Picker("Priority", selection: $priority) {
                    ForEach(TaskPriority.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }

                Stepper("Effort: \(effortMinutes)m", value: $effortMinutes, in: 0...480, step: 15)

                Toggle("Due date", isOn: $hasDueDate)
                if hasDueDate {
                    DatePicker("Date", selection: $dueDate, displayedComponents: .date)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { onSave() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    commit()
                    onSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 520)
        .frame(minHeight: 420)
        .onAppear { populate() }
    }

    private func populate() {
        title          = task.title
        description    = task.taskDescription
        priority       = task.priority
        effortMinutes  = task.effortEstimateMinutes
        hasDueDate     = task.dueDate != nil
        dueDate        = task.dueDate ?? Date()
    }

    private func commit() {
        task.title                  = title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.taskDescription        = description
        task.priority               = priority
        task.effortEstimateMinutes  = effortMinutes
        task.dueDate                = hasDueDate ? dueDate : nil
    }
}
