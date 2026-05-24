import SwiftData
import XCTest
@testable import Orin

/// Tests for RolloverEngine using an in-memory ModelContainer
/// so no disk state persists between test runs.
@MainActor
final class RolloverEngineTests: XCTestCase {

    private var container: ModelContainer!
    private var engine: RolloverEngine!
    private let udKey = "com.orin.lastRolloverTimestamp"

    override func setUp() async throws {
        try await super.setUp()
        let schema = Schema([
            TaskItem.self, SubTaskItem.self, MeetingItem.self,
            CommitmentItem.self, VaultItem.self, AISuggestionItem.self,
            DailyBriefItem.self, FocusPatternItem.self
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [config])
        engine = RolloverEngine(container: container)
        // Start each test without a stored rollover timestamp.
        UserDefaults.standard.removeObject(forKey: udKey)
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: udKey)
        container = nil
        engine = nil
        try await super.tearDown()
    }

    // MARK: - First launch (no stored timestamp)

    func testFirstLaunchSetsTimestampAndDoesNotMutateTasks() throws {
        let task = makeActiveTask(dueDate: yesterday)
        container.mainContext.insert(task)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        // Timestamp written, task unchanged (first-launch guard).
        XCTAssertNotNil(UserDefaults.standard.object(forKey: udKey))
        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(fetched.first?.dueDate, yesterday, "First launch must not roll over tasks")
    }

    // MARK: - Rollover skipped when same day

    func testNoRolloverWhenLastRolloverIsToday() throws {
        UserDefaults.standard.set(Date(), forKey: udKey)
        let task = makeActiveTask(dueDate: yesterday)
        container.mainContext.insert(task)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(fetched.first?.dueDate, yesterday, "Same-day guard must prevent rollover")
    }

    // MARK: - Overdue active tasks

    func testOverdueTasksDueDateMovedToToday() throws {
        UserDefaults.standard.set(yesterday, forKey: udKey)
        let overdueTask = makeActiveTask(dueDate: twoDaysAgo)
        container.mainContext.insert(overdueTask)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        let startOfToday = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(fetched.first?.dueDate, startOfToday, "Overdue task must move to today")
    }

    func testFutureDueDateTaskIsNotMoved() throws {
        UserDefaults.standard.set(yesterday, forKey: udKey)
        let futureTask = makeActiveTask(dueDate: tomorrow)
        container.mainContext.insert(futureTask)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(fetched.first?.dueDate, tomorrow, "Future task must not be moved")
    }

    func testTaskWithNoDueDateIsNotMoved() throws {
        UserDefaults.standard.set(yesterday, forKey: udKey)
        let task = makeActiveTask(dueDate: nil)
        container.mainContext.insert(task)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertNil(fetched.first?.dueDate)
    }

    func testCompletedTaskIsNotMoved() throws {
        UserDefaults.standard.set(yesterday, forKey: udKey)
        let task = makeTask(status: "completed", dueDate: twoDaysAgo, isBacklog: false)
        container.mainContext.insert(task)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertEqual(fetched.first?.dueDate, twoDaysAgo, "Completed task must not roll over")
    }

    // MARK: - Backlog activation

    func testBacklogTaskActivatesWhenTriggerDateReached() throws {
        UserDefaults.standard.set(yesterday, forKey: udKey)
        let backlog = makeTask(status: "active", dueDate: nil, isBacklog: true, triggerDate: yesterday)
        container.mainContext.insert(backlog)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        guard let result = fetched.first else { return XCTFail("No task found") }
        XCTAssertFalse(result.isBacklog, "Task must be moved out of backlog")
        XCTAssertNil(result.triggerDate, "triggerDate must be cleared after activation")
        XCTAssertNotNil(result.dueDate, "dueDate must be set to today on activation")
    }

    func testBacklogTaskWithFutureTriggerStaysInBacklog() throws {
        UserDefaults.standard.set(yesterday, forKey: udKey)
        let backlog = makeTask(status: "active", dueDate: nil, isBacklog: true, triggerDate: tomorrow)
        container.mainContext.insert(backlog)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        XCTAssertTrue(fetched.first?.isBacklog == true, "Future-trigger backlog task must stay in backlog")
    }

    // MARK: - Idempotency

    func testRolloverIsIdempotentOnSameDay() throws {
        UserDefaults.standard.set(yesterday, forKey: udKey)
        let task = makeActiveTask(dueDate: twoDaysAgo)
        container.mainContext.insert(task)
        try container.mainContext.save()

        engine.verifyAndExecuteRollover()
        engine.verifyAndExecuteRollover()  // second call same day — must be a no-op

        let fetched = try container.mainContext.fetch(FetchDescriptor<TaskItem>())
        let startOfToday = Calendar.current.startOfDay(for: Date())
        XCTAssertEqual(fetched.first?.dueDate, startOfToday)
    }

    // MARK: - Helpers

    private var yesterday: Date {
        Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))!
    }
    private var twoDaysAgo: Date {
        Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date()))!
    }
    private var tomorrow: Date {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
    }

    private func makeActiveTask(dueDate: Date?) -> TaskItem {
        makeTask(status: "active", dueDate: dueDate, isBacklog: false)
    }

    private func makeTask(
        status: String,
        dueDate: Date?,
        isBacklog: Bool,
        triggerDate: Date? = nil
    ) -> TaskItem {
        let task = TaskItem(
            title: "Test task",
            priority: .p2Medium,
            dueDate: dueDate,
            isBacklog: isBacklog
        )
        task.statusValue = status
        task.triggerDate = triggerDate
        return task
    }
}
