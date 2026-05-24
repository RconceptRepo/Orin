import SwiftData
import SwiftUI

struct TodayView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(
        filter: #Predicate<TaskItem> { !$0.isBacklog },
        sort: \TaskItem.dragOrderIndex
    )
    private var tasks: [TaskItem]
    @Query(sort: \MeetingItem.date)
    private var meetings: [MeetingItem]
    @Query(sort: \CommitmentItem.createdAt, order: .reverse)
    private var commitments: [CommitmentItem]
    @Query(sort: \AISuggestionItem.createdAt, order: .reverse)
    private var suggestions: [AISuggestionItem]
    @Query(sort: \FocusPatternItem.updatedAt, order: .reverse)
    private var focusPatterns: [FocusPatternItem]

    @AppStorage("orin.taskDragHintShown") private var dragHintShown = false
    @FocusState private var focusedTaskIndex: Int?

    @State private var isAddingTask = false
    @State private var isShowingReflow = false
    @State private var isReflowing = false
    @State private var reflowPlan: ReflowPlan?
    @State private var reflowOrderedTitles: [String] = []
    @State private var reflowFeedback: ReflowFeedback?
    @State private var dailyBrief: DailyBriefItem?
    @State private var taskToEdit: TaskItem?

    private let reflowEngine = ServiceContainer.shared.resolve(ReflowEngine.self)
    private let dailyBriefService = ServiceContainer.shared.resolve(DailyBriefService.self)

    // All active non-backlog tasks, ordered by dragOrderIndex (from @Query sort).
    // The @Query filter already excludes isBacklog tasks; we only need to drop completed ones.
    private var activeTodayTasks: [TaskItem] {
        tasks.filter { $0.status == .active }
    }

    private var completedTasks: [TaskItem] {
        tasks.filter { $0.status == .completed }
            .sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
    }

    private var openCommitments: [CommitmentItem] {
        commitments.filter { $0.statusValue != "fulfilled" }
    }

    private var visibleSuggestions: [AISuggestionItem] {
        suggestions.filter { suggestion in
            suggestion.status == .pending && suggestion.hiddenUntil.map { $0 > Date() } != true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrinSpacing.gap) {
            OrinPageHeader(title: "Today's Execution", subtitle: "Think Less. Do Better.") {
                HStack {
                    Button {
                        prepareReflow()
                    } label: {
                        if isReflowing {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.65)
                                Text("Reflowing…")
                            }
                            .frame(height: 36)
                            .padding(.horizontal, 14)
                        } else {
                            Label("Reflow", systemImage: "arrow.triangle.2.circlepath")
                        }
                    }
                    .buttonStyle(OrinSecondaryButtonStyle())
                    .disabled(isReflowing)

                    Button {
                        isAddingTask = true
                    } label: {
                        Label("Create Task", systemImage: "plus")
                    }
                    .buttonStyle(OrinPrimaryButtonStyle())
                }
            }

            if let feedback = reflowFeedback {
                reflowBanner(feedback)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: OrinSpacing.gap) {
                    if let dailyBrief {
                        DailyBriefCard(brief: dailyBrief)
                    }

                    if !visibleSuggestions.isEmpty {
                        AISuggestionsCard(
                            suggestions: visibleSuggestions,
                            onAccept: acceptSuggestion,
                            onDecline: declineSuggestion
                        )
                    }

                    activeTasksCard

                    if !openCommitments.isEmpty {
                        commitmentsCard
                    }

                    if !completedTasks.isEmpty {
                        completedCard
                    }
                }
            }
        }
        .padding(OrinSpacing.page)
        .background(OrinColor.backgroundPrimary(colorScheme))
        .onAppear {
            dailyBrief = dailyBriefService.generate(tasks: tasks, meetings: meetings, commitments: commitments)
            seedSuggestionIfNeeded()
        }
        .sheet(isPresented: $isAddingTask) {
            TaskEditorView(title: "Create Tasks", defaultDueDate: Date()) { drafts in
                save(drafts)
            }
        }
        .sheet(isPresented: $isShowingReflow) {
            ReflowPlanView(plan: reflowPlan, orderedTitles: reflowOrderedTitles, onApply: applyReflow)
        }
        .sheet(item: $taskToEdit) { task in
            TodayTaskEditSheet(task: task) {
                modelContext.safeSave(context: "task edits")
                taskToEdit = nil
            }
        }
    }

    private var activeTasksCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Active")
                        .font(OrinFont.sectionTitle)
                        .foregroundStyle(OrinColor.primaryText(colorScheme))
                    Spacer()
                    Text("\(activeTodayTasks.count)")
                        .font(OrinFont.caption.weight(.semibold))
                        .foregroundStyle(OrinColor.secondaryText(colorScheme))
                }

                if activeTodayTasks.isEmpty {
                    PlaceholderModuleView(
                        title: "No tasks for today",
                        systemImage: "checklist",
                        message: "Create the first task for today or activate something from Backlog.",
                        actionTitle: "Create Task",
                        action: { isAddingTask = true }
                    )
                    .frame(minHeight: 260)
                } else {
                    if !dragHintShown, activeTodayTasks.count >= 2 {
                        DragHintBanner {
                            withAnimation { dragHintShown = true }
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                        .padding(.bottom, 4)
                    }
                    List {
                        ForEach(activeTodayTasks) { task in
                            TaskRowView(
                                task: task,
                                showsDescription: true,
                                showsDragHandle: true,
                                onToggleComplete: { complete(task) },
                                onEdit: { taskToEdit = task },
                                onDelete: { delete(task) },
                                onBreakIntoSubtasks: { taskToEdit = task }
                            )
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                            .accessibilityAction(named: "Move Up") {
                                guard let idx = activeTodayTasks.firstIndex(where: { $0.id == task.id }), idx > 0 else { return }
                                moveTasks(from: IndexSet([idx]), to: idx - 1)
                            }
                            .accessibilityAction(named: "Move Down") {
                                guard let idx = activeTodayTasks.firstIndex(where: { $0.id == task.id }), idx < activeTodayTasks.count - 1 else { return }
                                moveTasks(from: IndexSet([idx]), to: idx + 2)
                            }
                        }
                        .onMove { from, to in moveTasks(from: from, to: to) }
                    }
                    .listStyle(.plain)
                    .scrollDisabled(true)
                    .frame(height: max(60, CGFloat(activeTodayTasks.count) * 62))
                }
            }
        }
    }

    private var commitmentsCard: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Commitments")
                    .font(OrinFont.sectionTitle)
                ForEach(openCommitments.prefix(5)) { commitment in
                    HStack {
                        Image(systemName: "person.crop.circle.badge.exclamationmark")
                            .foregroundStyle(OrinColor.warning)
                        Text(commitment.title)
                            .font(OrinFont.body)
                        Spacer()
                        Button("Fulfill") {
                            commitment.statusValue = "fulfilled"
                            modelContext.safeSave(context: "commitment")
                        }
                    }
                }
            }
        }
    }

    private var completedCard: some View {
        OrinCard {
            DisclosureGroup("\(completedTasks.count) completed") {
                VStack(spacing: 6) {
                    ForEach(completedTasks) { task in
                        TaskRowView(
                            task: task,
                            onToggleComplete: { reactivate(task) },
                            onDelete: { delete(task) },
                            onReactivate: { reactivate(task) }
                        )
                    }
                }
                .padding(.top, 8)
            }
            .font(OrinFont.cardTitle)
        }
    }

    private func save(_ drafts: [TaskDraft]) {
        let nextIndex = (tasks.map(\.dragOrderIndex).max() ?? -1) + 1
        for (offset, draft) in drafts.enumerated() {
            let task = TaskItem(
                title: draft.title,
                taskDescription: draft.description,
                priority: draft.priority,
                effortEstimateMinutes: draft.effortMinutes,
                dueDate: draft.hasDueDate ? draft.dueDate : nil,
                dragOrderIndex: nextIndex + offset
            )
            modelContext.insert(task)
        }
        modelContext.safeSave(context: "new tasks")
    }

    private func moveTasks(from source: IndexSet, to destination: Int) {
        var revisedItems = activeTodayTasks
        revisedItems.move(fromOffsets: source, toOffset: destination)
        for index in revisedItems.indices {
            revisedItems[index].dragOrderIndex = index
        }
        modelContext.safeSave(context: "task order")
    }

    private func prepareReflow() {
        let activeTasks = tasks.filter { $0.status == .active }
        guard !activeTasks.isEmpty else {
            showFeedback(.noTasks)
            return
        }
        isReflowing = true
        let plan = reflowEngine.generatePlan(tasks: tasks, meetings: meetings, focusPattern: focusPatterns.first)
        reflowOrderedTitles = plan.orderedTaskIDs.compactMap { id in tasks.first { $0.id == id }?.title }
        reflowPlan = plan
        isReflowing = false
        isShowingReflow = true
    }

    private func applyReflow() {
        guard let reflowPlan else { return }
        reflowEngine.apply(reflowPlan, to: tasks)
        do {
            try modelContext.save()
            showFeedback(.applied(count: reflowPlan.orderedTaskIDs.count))
        } catch {
            showFeedback(.saveFailed(error.localizedDescription))
        }
        isShowingReflow = false
    }

    private func showFeedback(_ feedback: ReflowFeedback) {
        withAnimation(.easeInOut(duration: 0.2)) {
            reflowFeedback = feedback
        }
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            withAnimation(.easeInOut(duration: 0.3)) { reflowFeedback = nil }
        }
    }

    @ViewBuilder
    private func reflowBanner(_ feedback: ReflowFeedback) -> some View {
        HStack(spacing: 8) {
            Image(systemName: feedback.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(feedback.isError ? OrinColor.error : OrinColor.success)
            Text(feedback.message)
                .font(OrinFont.body)
                .foregroundStyle(OrinColor.primaryText(colorScheme))
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { reflowFeedback = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background((feedback.isError ? OrinColor.error : OrinColor.success).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: OrinRadius.button, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: OrinRadius.button, style: .continuous)
                .stroke((feedback.isError ? OrinColor.error : OrinColor.success).opacity(0.3), lineWidth: 1)
        }
    }

    private func seedSuggestionIfNeeded() {
        guard suggestions.isEmpty, activeTodayTasks.count > 3 else { return }
        let suggestion = AISuggestionItem(
            title: "Reflow today's work",
            detail: "You have several active tasks. Orin can reorder them by urgency and effort.",
            suggestionType: "reflow"
        )
        modelContext.insert(suggestion)
        modelContext.safeSave(context: "suggestion")
    }

    private func acceptSuggestion(_ suggestion: AISuggestionItem) {
        if suggestion.suggestionType == "reflow" {
            prepareReflow()
        }
        suggestion.status = .accepted
        modelContext.safeSave(context: "suggestion")
    }

    private func declineSuggestion(_ suggestion: AISuggestionItem) {
        suggestion.status = .declined
        suggestion.hiddenUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        modelContext.safeSave(context: "suggestion")
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

// MARK: - Reflow feedback

private enum ReflowFeedback: Equatable {
    case applied(count: Int)
    case noTasks
    case saveFailed(String)

    var message: String {
        switch self {
        case .applied(let n): return "Reflow applied — \(n) task\(n == 1 ? "" : "s") reordered."
        case .noTasks:        return "No active tasks to reflow."
        case .saveFailed(let e): return "Failed to save reflow: \(e)"
        }
    }

    var isError: Bool {
        switch self {
        case .applied:    return false
        case .noTasks, .saveFailed: return true
        }
    }
}

// MARK: - Edit sheet
// List-based so ForEach.onMove gives drag-to-reorder for subtasks
// without nesting two scroll views.

private struct TodayTaskEditSheet: View {
    @Bindable var task: TaskItem
    var onSave: () -> Void
    @Environment(\.modelContext) private var modelContext

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
                Section("Task") {
                    TextField("Title", text: $title)
                        .accessibilityLabel("Task title")
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
                } header: {
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

// MARK: - Supporting card views

private struct DailyBriefCard: View {
    let brief: DailyBriefItem

    var body: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Daily Executive Brief")
                    .font(OrinFont.sectionTitle)
                Text(brief.focus)
                    .font(OrinFont.cardTitle)
                HStack(alignment: .top, spacing: 16) {
                    BriefColumn(title: "Critical", items: brief.criticalTasks)
                    BriefColumn(title: "Meetings", items: brief.meetings)
                    BriefColumn(title: "Commitments", items: brief.commitments)
                    BriefColumn(title: "Overdue", items: brief.overdueWork)
                }
                Text(brief.suggestedFocusBlock)
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct BriefColumn: View {
    let title: String
    let items: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(OrinFont.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if items.isEmpty {
                Text("None")
                    .font(OrinFont.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(3), id: \.self) { item in
                    Text(item)
                        .font(OrinFont.caption)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AISuggestionsCard: View {
    let suggestions: [AISuggestionItem]
    var onAccept: (AISuggestionItem) -> Void
    var onDecline: (AISuggestionItem) -> Void

    var body: some View {
        OrinCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Suggestion")
                    .font(OrinFont.sectionTitle)
                    .foregroundStyle(OrinColor.info)
                ForEach(suggestions) { suggestion in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(suggestion.title)
                                .font(OrinFont.cardTitle)
                            Text(suggestion.detail)
                                .font(OrinFont.body)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Decline") { onDecline(suggestion) }
                            .buttonStyle(OrinSecondaryButtonStyle())
                        Button("Accept") { onAccept(suggestion) }
                            .buttonStyle(OrinPrimaryButtonStyle())
                    }
                }
            }
        }
    }
}

private struct ReflowPlanView: View {
    let plan: ReflowPlan?
    let orderedTitles: [String]
    var onApply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Reflow Day")
                .font(OrinFont.pageTitle)

            if let plan {
                Text(plan.rationale)
                    .font(OrinFont.body)
                    .foregroundStyle(.secondary)

                // New task order
                OrinCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("New Task Order")
                                .font(OrinFont.cardTitle)
                            Spacer()
                            Text("\(orderedTitles.count) task\(orderedTitles.count == 1 ? "" : "s")")
                                .font(OrinFont.caption)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(Array(orderedTitles.enumerated()), id: \.offset) { index, title in
                            HStack(spacing: 10) {
                                Text("\(index + 1)")
                                    .font(OrinFont.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 18, alignment: .trailing)
                                Text(title)
                                    .font(OrinFont.body)
                                    .lineLimit(1)
                            }
                        }
                    }
                }

                // Focus blocks
                if !plan.focusBlocks.isEmpty {
                    OrinCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Suggested Focus Blocks")
                                .font(OrinFont.cardTitle)
                            ForEach(plan.focusBlocks, id: \.self) { block in
                                Label(block, systemImage: "calendar.badge.clock")
                                    .font(OrinFont.body)
                            }
                            ForEach(plan.breaks, id: \.self) { breakText in
                                Label(breakText, systemImage: "cup.and.saucer")
                                    .font(OrinFont.body)
                            }
                        }
                    }
                }
            } else {
                Text("No tasks to reflow.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(OrinSecondaryButtonStyle())
                Button("Apply \(orderedTitles.count) Task\(orderedTitles.count == 1 ? "" : "s")", action: onApply)
                    .buttonStyle(OrinPrimaryButtonStyle())
                    .disabled(plan == nil || orderedTitles.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 380)
    }
}
