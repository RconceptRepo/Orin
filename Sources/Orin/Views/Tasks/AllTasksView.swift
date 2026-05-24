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
                    TaskRowView(
                        task: task,
                        showsDescription: true,
                        onToggleComplete: {
                            if task.status == .active { complete(task) } else { reactivate(task) }
                        },
                        onEdit: { taskToEdit = task },
                        onDelete: { delete(task) },
                        onBreakIntoSubtasks: { taskToEdit = task },
                        onReactivate: task.status == .completed ? { reactivate(task) } : nil
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
        .padding()
        .sheet(item: $taskToEdit) { task in
            TaskEditSheet(task: task) {
                modelContext.safeSave(context: "task edits")
                taskToEdit = nil
            }
        }
    }

    private func complete(_ task: TaskItem) {
        task.status = .completed
        task.completedAt = Date()
        modelContext.safeSave(context: "task")
    }

    private func reactivate(_ task: TaskItem) {
        task.status = .active
        task.completedAt = nil
        modelContext.safeSave(context: "task")
    }

    private func delete(_ task: TaskItem) {
        modelContext.delete(task)
        modelContext.safeSave(context: "task")
    }
}

// MARK: - TaskEditSheet
// Shared edit sheet used by AllTasksView and BacklogView.
// Uses a List with two sections so ForEach.onMove gives drag-to-reorder for subtasks
// without nesting two scroll views.

struct TaskEditSheet: View {
    @Bindable var task: TaskItem
    var onSave: () -> Void
    @Environment(\.modelContext) private var modelContext

    // Task field drafts — applied on Save; subtask changes are persisted immediately.
    @State private var title: String = ""
    @State private var description: String = ""
    @State private var priority: TaskPriority = .p3Low
    @State private var effortMinutes: Int = 0
    @State private var hasDueDate: Bool = false
    @State private var dueDate: Date = Date()

    @State private var newSubtaskTitle = ""
    @FocusState private var isAddSubtaskFocused: Bool

    private var sortedSubtasks: [SubTaskItem] {
        task.subtasks.sorted { $0.sortIndex < $1.sortIndex }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Edit Task")
                .font(.title2.weight(.semibold))
                .padding(.bottom, 16)

            List {
                // MARK: Task fields
                Section("Task") {
                    TextField("Title", text: $title)
                        .accessibilityLabel("Task title")
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(2...4)
                        .accessibilityLabel("Task description")
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

                // MARK: Subtasks
                Section {
                    ForEach(sortedSubtasks) { subtask in
                        SubtaskEditRow(
                            subtask: subtask,
                            onDelete: { deleteSubtask(subtask) },
                            onChange: { saveSubtasks() }
                        )
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                    }
                    .onMove(perform: moveSubtasks)

                    // Add-subtask inline field
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle")
                            .foregroundStyle(OrinColor.accent)
                        TextField("Add subtask", text: $newSubtaskTitle)
                            .focused($isAddSubtaskFocused)
                            .onSubmit { addSubtask() }
                        if !newSubtaskTitle.isEmpty {
                            Button("Add") { addSubtask() }
                                .buttonStyle(.plain)
                                .foregroundStyle(OrinColor.accent)
                                .font(OrinFont.caption.weight(.semibold))
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                    .accessibilityLabel("Add subtask field")
                } header: {
                    subtaskHeader
                }
            }
            .listStyle(.inset)

            Divider().padding(.top, 4)
            HStack {
                Spacer()
                Button("Cancel") { onSave() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { commit(); onSave() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.top, 10)
        }
        .padding(22)
        .frame(width: 560)
        .frame(minHeight: 560)
        .onAppear { populate() }
    }

    private var subtaskHeader: some View {
        HStack {
            Text("Subtasks")
            Spacer()
            let done = task.subtasks.filter(\.isCompleted).count
            let total = task.subtasks.count
            if total > 0 {
                Text("\(done)/\(total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    // MARK: - Subtask operations (immediate persistence)

    private func addSubtask() {
        let t = newSubtaskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        let nextIndex = (task.subtasks.map(\.sortIndex).max() ?? -1) + 1
        let sub = SubTaskItem(title: t, sortIndex: nextIndex)
        task.subtasks.append(sub)
        newSubtaskTitle = ""
        saveSubtasks()
    }

    private func deleteSubtask(_ subtask: SubTaskItem) {
        task.subtasks.removeAll { $0.id == subtask.id }
        modelContext.delete(subtask)
        saveSubtasks()
    }

    private func moveSubtasks(from source: IndexSet, to destination: Int) {
        var sorted = sortedSubtasks
        sorted.move(fromOffsets: source, toOffset: destination)
        for (idx, sub) in sorted.enumerated() { sub.sortIndex = idx }
        saveSubtasks()
    }

    private func saveSubtasks() {
        modelContext.safeSave(context: "subtask")
    }

    // MARK: - Task field helpers

    private func populate() {
        title         = task.title
        description   = task.taskDescription
        priority      = task.priority
        effortMinutes = task.effortEstimateMinutes
        hasDueDate    = task.dueDate != nil
        dueDate       = task.dueDate ?? Date()
    }

    private func commit() {
        task.title                 = title.trimmingCharacters(in: .whitespacesAndNewlines)
        task.taskDescription       = description
        task.priority              = priority
        task.effortEstimateMinutes = effortMinutes
        task.dueDate               = hasDueDate ? dueDate : nil
    }
}
