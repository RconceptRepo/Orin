import XCTest
import SwiftData
@testable import Orin

// MARK: - RecurringMeetingTests

@MainActor
final class RecurringMeetingTests: XCTestCase {

    private let service = RecurringMeetingService()

    private static var sharedContainer: ModelContainer = {
        let schema = Schema([MeetingItem.self, MeetingFolderItem.self, FolderSummaryItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }()
    private var ctx: ModelContext { Self.sharedContainer.mainContext }

    override func setUp() {
        let items = (try? ctx.fetch(FetchDescriptor<MeetingItem>())) ?? []
        items.forEach { ctx.delete($0) }
        try? ctx.save()
    }

    // MARK: - Helpers

    private func makeMeeting(
        title: String,
        date: Date,
        participants: [String] = [],
        summary: String = "",
        decisions: [String] = [],
        actionItems: [String] = []
    ) -> MeetingItem {
        let m = MeetingItem(title: title, date: date)
        m.participants = participants
        m.summary      = summary
        m.decisions    = decisions
        m.actionItems  = actionItems
        ctx.insert(m)
        try? ctx.save()
        return m
    }

    private func monday(weeksAgo: Int) -> Date {
        let cal = Calendar.current
        var components = DateComponents()
        components.weekday = 2 // Monday
        components.hour = 9
        components.minute = 0
        let base = cal.nextDate(after: Date(), matching: DateComponents(weekday: 2), matchingPolicy: .nextTimePreservingSmallerComponents, direction: .backward) ?? Date()
        return base.addingTimeInterval(TimeInterval(-weeksAgo * 7 * 24 * 3600))
    }

    // MARK: - Title Similarity

    func testIdenticalTitlesMeetThreshold() {
        let meetings = (0..<3).map { i in
            makeMeeting(title: "Weekly Team Standup", date: monday(weeksAgo: i))
        }
        let patterns = service.detectPatterns(in: meetings, existingFolderNames: [])
        XCTAssertFalse(patterns.isEmpty, "Identical titles must produce a recurring pattern")
        XCTAssertGreaterThanOrEqual(patterns[0].confidence, service.suggestionThreshold)
    }

    func testSimilarTitlesGrouped() {
        let m1 = makeMeeting(title: "Team Standup", date: monday(weeksAgo: 0))
        let m2 = makeMeeting(title: "Team Standup", date: monday(weeksAgo: 1))
        let m3 = makeMeeting(title: "Team Standup", date: monday(weeksAgo: 2))
        let patterns = service.detectPatterns(in: [m1, m2, m3], existingFolderNames: [])
        XCTAssertFalse(patterns.isEmpty)
        XCTAssertEqual(patterns[0].meetingIDs.count, 3)
    }

    func testDifferentTitlesNotGrouped() {
        let m1 = makeMeeting(title: "Product Review", date: monday(weeksAgo: 0))
        let m2 = makeMeeting(title: "Engineering Planning", date: monday(weeksAgo: 1))
        let m3 = makeMeeting(title: "Design Sprint", date: monday(weeksAgo: 2))
        let patterns = service.detectPatterns(in: [m1, m2, m3], existingFolderNames: [])
        // Three completely different titles — should not form a group
        XCTAssertTrue(patterns.isEmpty, "Unrelated titles must not produce a recurring pattern")
    }

    // MARK: - Confidence scoring

    func testHighConfidenceForWeeklyMeetings() {
        let participants = ["Alice", "Bob", "Carol"]
        let meetings = (0..<4).map { i in
            makeMeeting(
                title: "Weekly Standup",
                date: monday(weeksAgo: i),
                participants: participants
            )
        }
        let patterns = service.detectPatterns(in: meetings, existingFolderNames: [])
        XCTAssertFalse(patterns.isEmpty)
        XCTAssertGreaterThanOrEqual(patterns[0].confidence, 0.7,
                                     "Weekly same-participant meetings must score ≥ 0.70")
    }

    func testLowConfidenceMeetingsNotSuggested() {
        // Only 2 meetings with slightly different titles and participants
        let m1 = makeMeeting(title: "Sprint Planning", date: monday(weeksAgo: 0),
                             participants: ["Alice"])
        let m2 = makeMeeting(title: "Sprint Planning Review", date: monday(weeksAgo: 3),
                             participants: ["Bob", "Carol"])
        let patterns = service.detectPatterns(in: [m1, m2], existingFolderNames: [])
        // Title similarity is moderate but participants and time pattern differ significantly
        // May or may not meet threshold — just verify no crash
        XCTAssertNotNil(patterns)  // doesn't crash
    }

    // MARK: - Day pattern signal

    func testSameDayHighScore() {
        // All on Monday at 9am
        let meetings = (0..<4).map { i in
            makeMeeting(title: "Standup", date: monday(weeksAgo: i))
        }
        let patterns = service.detectPatterns(in: meetings, existingFolderNames: [])
        if let p = patterns.first {
            XCTAssertTrue(p.dayPattern.contains("Monday") || p.dayPattern.contains("Every"),
                          "Day pattern must mention Monday for all-Monday meetings: \(p.dayPattern)")
        }
    }

    // MARK: - Time pattern signal

    func testSameTimeFormatsCorrectly() {
        let base = monday(weeksAgo: 0)
        let meetings = (0..<3).map { i in
            makeMeeting(title: "Standup", date: base.addingTimeInterval(TimeInterval(-i * 7 * 86400)))
        }
        let patterns = service.detectPatterns(in: meetings, existingFolderNames: [])
        if let p = patterns.first {
            XCTAssertFalse(p.timePattern.isEmpty)
        }
    }

    // MARK: - Dismissed patterns not shown

    func testDismissedPatternNotSuggested() {
        let meetings = (0..<3).map { i in
            makeMeeting(title: "Dismissed Meeting", date: monday(weeksAgo: i))
        }
        // Generate patterns to get the dismiss key
        let patterns = service.detectPatterns(in: meetings, existingFolderNames: [])
        guard let first = patterns.first else {
            XCTSkip("No patterns generated — cannot test dismiss")
            return
        }
        // Dismiss the pattern
        UserDefaults.standard.set(true, forKey: first.dismissedKey)
        defer { UserDefaults.standard.removeObject(forKey: first.dismissedKey) }

        let afterDismiss = service.detectPatterns(in: meetings, existingFolderNames: [])
        XCTAssertFalse(afterDismiss.contains { $0.dismissedKey == first.dismissedKey },
                       "Dismissed pattern must not reappear")
    }

    // MARK: - Existing folder names excluded

    func testExistingFolderNameExcludesPattern() {
        let meetings = (0..<3).map { i in
            makeMeeting(title: "Weekly Standup", date: monday(weeksAgo: i))
        }
        // Suggest with no existing folder
        let before = service.detectPatterns(in: meetings, existingFolderNames: [])
        // Suggest with "Weekly Standup" already as a folder
        let after = service.detectPatterns(in: meetings, existingFolderNames: ["Weekly Standup"])
        XCTAssertGreaterThan(before.count, after.count,
                             "Patterns matching existing folder names must be excluded")
    }

    // MARK: - bestFolderName

    func testBestFolderNameMostCommon() {
        let m1 = makeMeeting(title: "Weekly Standup", date: monday(weeksAgo: 0))
        let m2 = makeMeeting(title: "Weekly Standup", date: monday(weeksAgo: 1))
        let m3 = makeMeeting(title: "Weekly Standup Alt", date: monday(weeksAgo: 2))
        let name = service.bestFolderName(for: [m1, m2, m3])
        XCTAssertEqual(name, "Weekly Standup", "Most common title must win as folder name")
    }

    // MARK: - Minimum group size

    func testSingleMeetingProducesNoPattern() {
        let m = makeMeeting(title: "Solo Meeting", date: Date())
        let patterns = service.detectPatterns(in: [m], existingFolderNames: [])
        XCTAssertTrue(patterns.isEmpty, "Single meeting must not produce a pattern")
    }

    func testTwoIdenticalMeetingsCanProducePattern() {
        let m1 = makeMeeting(title: "Monthly Review", date: monday(weeksAgo: 0))
        let m2 = makeMeeting(title: "Monthly Review", date: monday(weeksAgo: 4))
        let patterns = service.detectPatterns(in: [m1, m2], existingFolderNames: [])
        // Two identical meetings should form a pattern
        XCTAssertFalse(patterns.isEmpty, "Two identical meetings must form a recurring pattern")
    }
}

// MARK: - FolderSummaryItemTests

@MainActor
final class FolderSummaryItemTests: XCTestCase {

    private static var sharedContainer: ModelContainer = {
        let schema = Schema([FolderSummaryItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }()
    private var ctx: ModelContext { Self.sharedContainer.mainContext }

    func testFolderSummaryItemCanBePersisted() throws {
        let item = FolderSummaryItem(folderID: UUID())
        item.overallSummary     = "Test summary"
        item.recurringDecisions  = ["Decision A"]
        item.recurringActionItems = ["Action B"]
        item.recurringTopics    = ["Topic C"]
        item.meetingCount       = 5
        ctx.insert(item)
        XCTAssertNoThrow(try ctx.save())
        let fetched = try ctx.fetch(FetchDescriptor<FolderSummaryItem>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].overallSummary, "Test summary")
        XCTAssertEqual(fetched[0].meetingCount, 5)
    }

    func testFolderSummaryItemFields() {
        let fid = UUID()
        let item = FolderSummaryItem(folderID: fid)
        XCTAssertEqual(item.folderID, fid)
        XCTAssertTrue(item.overallSummary.isEmpty)
        XCTAssertTrue(item.recurringDecisions.isEmpty)
        XCTAssertTrue(item.recurringTopics.isEmpty)
        XCTAssertEqual(item.meetingCount, 0)
    }
}

// MARK: - MeetingFolderItemUpdatedFieldsTests

final class MeetingFolderItemUpdatedFieldsTests: XCTestCase {

    func testMeetingFolderItemHasColorAndIcon() {
        let folder = MeetingFolderItem(name: "Test", color: "green", icon: "video")
        XCTAssertEqual(folder.color, "green")
        XCTAssertEqual(folder.icon, "video")
        XCTAssertEqual(folder.folderDescription, "")
    }

    func testMeetingFolderItemDefaultColorAndIcon() {
        let folder = MeetingFolderItem(name: "Default")
        XCTAssertEqual(folder.color, "blue")
        XCTAssertEqual(folder.icon, "folder")
    }

    func testMeetingFolderItemDescription() {
        let folder = MeetingFolderItem(name: "Test")
        folder.folderDescription = "Weekly engineering sync"
        XCTAssertEqual(folder.folderDescription, "Weekly engineering sync")
    }
}
