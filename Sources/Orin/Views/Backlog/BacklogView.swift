import SwiftData
import SwiftUI

struct BacklogView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<TaskItem> { $0.isBacklog },
        sort: \TaskItem.createdAt,
        order: .reverse
    )
    private var backlogItems: [TaskItem]

    @State private var isAddingBacklogItem = false
    @State private var taskToEdit: TaskItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Backlog")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    isAddingBacklogItem = true
                } label: {
                    Label("New Backlog Item", systemImage: "plus")
                }
            }

            List {
                ForEach(backlogItems) { item in
                    TaskRowView(
                        task: item,
                        showsDescription: true,
                        onEdit: { taskToEdit = item },
                        onDelete: { delete(item) },
                        onBreakIntoSubtasks: { taskToEdit = item },
                        onActivate: { activate(item) }
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
        }
        .padding()
        .sheet(isPresented: $isAddingBacklogItem) {
            TaskEditorView(title: "Create Backlog Items", defaultDueDate: nil) { drafts in
                save(drafts)
            }
        }
        .sheet(item: $taskToEdit) { item in
            TaskEditSheet(task: item) {
                try? modelContext.save()
                taskToEdit = nil
            }
        }
    }

    private func save(_ drafts: [TaskDraft]) {
        for draft in drafts {
            let task = TaskItem(
                title: draft.title,
                taskDescription: draft.description,
                priority: draft.priority,
                effortEstimateMinutes: draft.effortMinutes,
                dueDate: nil,
                isBacklog: true,
                triggerDate: draft.hasDueDate ? draft.dueDate : nil
            )
            modelContext.insert(task)
        }
        try? modelContext.save()
    }

    private func activate(_ item: TaskItem) {
        item.isBacklog = false
        item.triggerDate = nil
        item.dueDate = Calendar.current.startOfDay(for: Date())
        try? modelContext.save()
    }

    private func delete(_ item: TaskItem) {
        modelContext.delete(item)
        try? modelContext.save()
    }

}
