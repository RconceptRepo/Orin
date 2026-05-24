import XCTest
import SwiftData
@testable import Orin

final class MeetingRetentionServiceTests: XCTestCase {

    private var service: MeetingRetentionService!
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        try await super.setUp()
        service = MeetingRetentionService()
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
        service = nil
        try await super.tearDown()
    }

    // MARK: - Retention policy helpers

    func testForeverPolicyNeverPrunes() throws {
        insertMeeting(daysAgo: 365)
        insertMeeting(daysAgo: 1000)
        let pruned = try service.pruneExpiredMeetings(in: context, policy: .forever)
        XCTAssertEqual(pruned, 0)
        XCTAssertEqual(fetchAllMeetings().count, 2)
    }

    func testThirtyDayPolicyDeletesOldMeeting() throws {
        insertMeeting(daysAgo: 31)
        let pruned = try service.pruneExpiredMeetings(in: context, policy: .thirtyDays)
        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(fetchAllMeetings().count, 0)
    }

    func testThirtyDayPolicyKeepsRecentMeeting() throws {
        insertMeeting(daysAgo: 29)
        let pruned = try service.pruneExpiredMeetings(in: context, policy: .thirtyDays)
        XCTAssertEqual(pruned, 0)
        XCTAssertEqual(fetchAllMeetings().count, 1)
    }

    func testNinetyDayPolicy() throws {
        insertMeeting(daysAgo: 91)  // should be deleted
        insertMeeting(daysAgo: 89)  // should be kept
        let pruned = try service.pruneExpiredMeetings(in: context, policy: .ninetyDays)
        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(fetchAllMeetings().count, 1)
    }

    func testOneEightyDayPolicy() throws {
        insertMeeting(daysAgo: 181)  // deleted
        insertMeeting(daysAgo: 179)  // kept
        let pruned = try service.pruneExpiredMeetings(in: context, policy: .oneEightyDays)
        XCTAssertEqual(pruned, 1)
        XCTAssertEqual(fetchAllMeetings().count, 1)
    }

    func testMixedMeetingsWithThirtyDayPolicy() throws {
        insertMeeting(daysAgo: 100)  // deleted
        insertMeeting(daysAgo: 60)   // deleted
        insertMeeting(daysAgo: 10)   // kept
        insertMeeting(daysAgo: 0)    // kept (today)
        let pruned = try service.pruneExpiredMeetings(in: context, policy: .thirtyDays)
        XCTAssertEqual(pruned, 2)
        XCTAssertEqual(fetchAllMeetings().count, 2)
    }

    func testCutoffDateCalculation() {
        let cutoff = service.cutoffDate(for: .thirtyDays)
        let expected = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        XCTAssertEqual(cutoff.timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 60)
    }

    func testRetentionPolicyDisplayNames() {
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.thirtyDays.displayName,    "30 days")
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.ninetyDays.displayName,    "90 days")
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.oneEightyDays.displayName, "180 days")
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.forever.displayName,       "Forever")
    }

    func testRetentionPolicyFromRawValue() {
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.from(rawValue: 30),  .thirtyDays)
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.from(rawValue: 90),  .ninetyDays)
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.from(rawValue: 180), .oneEightyDays)
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.from(rawValue: 0),   .forever)
        XCTAssertEqual(MeetingRetentionService.RetentionPolicy.from(rawValue: 999), .thirtyDays, "Unknown raw value falls back to default")
    }

    // MARK: - Helpers

    private func insertMeeting(daysAgo: Int) {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date())!
        let meeting = MeetingItem(title: "Meeting \(UUID().uuidString.prefix(6))", date: date)
        context.insert(meeting)
        try? context.save()
    }

    private func fetchAllMeetings() -> [MeetingItem] {
        (try? context.fetch(FetchDescriptor<MeetingItem>())) ?? []
    }
}
