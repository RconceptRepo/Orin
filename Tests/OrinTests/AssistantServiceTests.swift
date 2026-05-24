import XCTest
import SwiftData
@testable import Orin

/// Tests AssistantService.buildTodaySummary and task-creation logic.
final class AssistantServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([
            TaskItem.self, SubTaskItem.self, MeetingItem.self, CommitmentItem.self,
            VaultItem.self, AISuggestionItem.self, DailyBriefItem.self, FocusPatternItem.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        context = await MainActor.run { container.mainContext }
    }

    override func tearDown() async throws {
        context = nil
        container = nil
        try await super.tearDown()
    }

    // MARK: - buildTodaySummary

    func testSummaryWhenNoTasks() throws {
        let summary = try AssistantService.buildTodaySummary(from: context)
        XCTAssertTrue(summary.lowercased().contains("no active"), "Should report no tasks")
    }

    func testSummaryListsActiveTasks() throws {
        insert(title: "Write unit tests", priority: .p1High)
        insert(title: "Review PR", priority: .p2Medium)
        let summary = try AssistantService.buildTodaySummary(from: context)
        XCTAssertTrue(summary.contains("Write unit tests"))
        XCTAssertTrue(summary.contains("Review PR"))
    }

    func testSummarySkipsBacklogTasks() throws {
        let task = TaskItem(title: "Backlog item", isBacklog: true)
        context.insert(task)
        try? context.save()
        let summary = try AssistantService.buildTodaySummary(from: context)
        XCTAssertFalse(summary.contains("Backlog item"))
    }

    func testSummarySkipsCompletedTasks() throws {
        let task = TaskItem(title: "Done already")
        task.status = .completed
        context.insert(task)
        try? context.save()
        let summary = try AssistantService.buildTodaySummary(from: context)
        XCTAssertFalse(summary.contains("Done already"))
    }

    func testSummaryLimitsFiveItems() throws {
        for i in 1...8 { insert(title: "Task \(i)", priority: .p3Low) }
        let summary = try AssistantService.buildTodaySummary(from: context)
        // Bullet points: count "•" chars
        let bulletCount = summary.components(separatedBy: "•").count - 1
        XCTAssertLessThanOrEqual(bulletCount, 5, "Summary must cap at 5 tasks")
    }

    func testSummaryOrdersByPriority() throws {
        insert(title: "Low task",      priority: .p3Low)
        insert(title: "Critical task", priority: .p0Critical)
        let summary = try AssistantService.buildTodaySummary(from: context)
        let criticalRange = summary.range(of: "Critical task")!
        let lowRange      = summary.range(of: "Low task")!
        XCTAssertLessThan(criticalRange.lowerBound, lowRange.lowerBound, "Critical task should appear before low task")
    }

    // MARK: - Helpers

    private func insert(title: String, priority: TaskPriority = .p3Low) {
        let task = TaskItem(title: title, priority: priority)
        context.insert(task)
        try? context.save()
    }
}
