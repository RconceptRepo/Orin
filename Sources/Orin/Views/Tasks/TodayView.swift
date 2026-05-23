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

    @State private var isAddingTask = false
    @State private var isShowingReflow = false
    @State private var reflowPlan: ReflowPlan?
    @State private var dailyBrief: DailyBriefItem?

    private let reflowEngine = ServiceContainer.shared.resolve(ReflowEngine.self)
    private let dailyBriefService = ServiceContainer.shared.resolve(DailyBriefService.self)

    private var activeTodayTasks: [TaskItem] {
        tasks.filter { task in
            task.status == .active && task.dueDate.map { Calendar.current.isDateInToday($0) || $0 < Calendar.current.startOfDay(for: Date()) } == true
        }
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
                        Label("Reflow", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(OrinSecondaryButtonStyle())

                    Button {
                        isAddingTask = true
                    } label: {
                        Label("Create Task", systemImage: "plus")
                    }
                    .buttonStyle(OrinPrimaryButtonStyle())
                }
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
            ReflowPlanView(plan: reflowPlan, onApply: applyReflow)
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
                    VStack(spacing: 6) {
                        ForEach(activeTodayTasks) { task in
                            TaskRowView(task: task, showsDescription: true, onToggleComplete: { complete(task) })
                                .contextMenu {
                                    Button("Complete") { complete(task) }
                                    Button("Edit") {}
                                    Button("Break Into Subtasks") { addDefaultSubtasks(to: task) }
                                    Button("Delete", role: .destructive) { delete(task) }
                                }
                        }
                    }
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
                            try? modelContext.save()
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
                        TaskRowView(task: task, onToggleComplete: { reactivate(task) })
                            .contextMenu {
                                Button("Reactivate") { reactivate(task) }
                                Button("Delete", role: .destructive) { delete(task) }
                            }
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
        try? modelContext.save()
    }

    private func moveTasks(from source: IndexSet, to destination: Int) {
        var revisedItems = activeTodayTasks
        revisedItems.move(fromOffsets: source, toOffset: destination)
        for index in revisedItems.indices {
            revisedItems[index].dragOrderIndex = index
        }
        try? modelContext.save()
    }

    private func prepareReflow() {
        reflowPlan = reflowEngine.generatePlan(tasks: tasks, meetings: meetings, focusPattern: focusPatterns.first)
        isShowingReflow = true
    }

    private func applyReflow() {
        guard let reflowPlan else { return }
        reflowEngine.apply(reflowPlan, to: tasks)
        try? modelContext.save()
        isShowingReflow = false
    }

    private func seedSuggestionIfNeeded() {
        guard suggestions.isEmpty, activeTodayTasks.count > 3 else { return }
        let suggestion = AISuggestionItem(
            title: "Reflow today's work",
            detail: "You have several active tasks. Orin can reorder them by urgency and effort.",
            suggestionType: "reflow"
        )
        modelContext.insert(suggestion)
        try? modelContext.save()
    }

    private func acceptSuggestion(_ suggestion: AISuggestionItem) {
        if suggestion.suggestionType == "reflow" {
            prepareReflow()
        }
        suggestion.status = .accepted
        try? modelContext.save()
    }

    private func declineSuggestion(_ suggestion: AISuggestionItem) {
        suggestion.status = .declined
        suggestion.hiddenUntil = Calendar.current.date(byAdding: .day, value: 1, to: Date())
        try? modelContext.save()
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
                OrinCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Suggested Focus Blocks")
                            .font(OrinFont.cardTitle)
                        ForEach(plan.focusBlocks, id: \.self) { block in
                            Label(block, systemImage: "calendar.badge.clock")
                        }
                        ForEach(plan.breaks, id: \.self) { breakText in
                            Label(breakText, systemImage: "cup.and.saucer")
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Reject") { dismiss() }
                    .buttonStyle(OrinSecondaryButtonStyle())
                Button("Apply", action: onApply)
                    .buttonStyle(OrinPrimaryButtonStyle())
                    .disabled(plan == nil)
            }
        }
        .padding(24)
        .frame(width: 560)
    }
}
