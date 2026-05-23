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
                                Button("Edit") {}
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
