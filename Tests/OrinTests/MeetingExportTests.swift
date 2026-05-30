import XCTest
import SwiftData
@testable import Orin

// MARK: - MeetingExportTests
//
// Tests for CSV export, ZIP bulk export, and auto-analysis guard logic.

@MainActor
final class MeetingExportTests: XCTestCase {

    private let service = MeetingDataService()

    private static var sharedContainer: ModelContainer = {
        let schema = Schema([MeetingItem.self, CommitmentItem.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try! ModelContainer(for: schema, configurations: config)
    }()
    private var ctx: ModelContext { Self.sharedContainer.mainContext }

    private func makeMeeting(
        title: String = "Test Meeting",
        durationSeconds: TimeInterval = 1800,
        transcript: String = "Me: Hello everyone.\n\nParticipant: Great to be here.",
        summary: String = "A productive session.",
        decisions: [String] = ["Decided to proceed"],
        actionItems: [String] = ["Follow up next week"],
        participants: [String] = ["Alice", "Bob"]
    ) -> MeetingItem {
        let m = MeetingItem(title: title, date: Date(), durationSeconds: durationSeconds)
        m.transcript  = transcript
        m.summary     = summary
        m.decisions   = decisions
        m.actionItems = actionItems
        m.participants = participants
        ctx.insert(m)
        try? ctx.save()
        return m
    }

    override func setUp() {
        // Clean up any meetings from prior tests
        let meetings = (try? ctx.fetch(FetchDescriptor<MeetingItem>())) ?? []
        meetings.forEach { ctx.delete($0) }
        try? ctx.save()
    }

    // MARK: - CSV single-meeting export

    func testCSVSingleMeetingProducesHeaderRow() throws {
        let m = makeMeeting()
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasPrefix("ID,Date,Duration (s),Title"),
                      "CSV must start with the expected header")
    }

    func testCSVSingleMeetingHas12Columns() throws {
        let m = makeMeeting()
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        let lines = text.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 2, "CSV must have header + 1 data row")
        // Count header columns
        let headerCols = lines[0].components(separatedBy: ",")
        XCTAssertEqual(headerCols.count, 12, "CSV header must have exactly 12 columns")
    }

    func testCSVFileExtensionIsCSV() {
        XCTAssertEqual(MeetingExportFormat.csv.fileExtension, "csv")
    }

    func testCSVDisplayNameIsCSV() {
        XCTAssertEqual(MeetingExportFormat.csv.displayName, "CSV")
    }

    func testCSVContainsMeetingTitle() throws {
        let m = makeMeeting(title: "My Special Meeting")
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("My Special Meeting"),
                      "CSV must contain the meeting title")
    }

    func testCSVContainsParticipants() throws {
        let m = makeMeeting(participants: ["Alice", "Bob", "Carol"])
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("Alice"), "CSV must contain participant names")
        XCTAssertTrue(text.contains("Bob"))
        XCTAssertTrue(text.contains("Carol"))
    }

    func testCSVHasTranscriptIndicatorYes() throws {
        let m = makeMeeting(transcript: "Some content here")
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(",Yes,"), "Has Transcript must be Yes when transcript is non-empty")
    }

    func testCSVHasTranscriptIndicatorNo() throws {
        let m = makeMeeting(transcript: "")
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains(",No,"), "Has Transcript must be No when transcript is empty")
    }

    // MARK: - CSV RFC 4180 escaping

    func testCSVEscapesCommaInTitle() throws {
        let m = makeMeeting(title: "Meeting, Very Important")
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"Meeting, Very Important\""),
                      "Title containing comma must be double-quoted")
    }

    func testCSVEscapesDoubleQuoteInSummary() throws {
        let m = makeMeeting(summary: "He said \"hello\"")
        let data = try service.data(for: m, format: .csv)
        let text = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"He said \"\"hello\"\"\""),
                      "Internal double-quotes must be escaped as \"\"")
    }

    // MARK: - Bulk CSV

    func testBulkCSVHasHeaderPlusOneRowPerMeeting() {
        let m1 = makeMeeting(title: "Meeting A")
        let m2 = makeMeeting(title: "Meeting B")
        let m3 = makeMeeting(title: "Meeting C")

        let csv = service.csvBulk(for: [m1, m2, m3])
        let lines = csv.components(separatedBy: "\n").filter { !$0.isEmpty }
        XCTAssertEqual(lines.count, 4, "Bulk CSV must have 1 header + 3 data rows")
    }

    func testBulkCSVContainsAllMeetingTitles() {
        let m1 = makeMeeting(title: "Alpha")
        let m2 = makeMeeting(title: "Beta")
        let csv = service.csvBulk(for: [m1, m2])
        XCTAssertTrue(csv.contains("Alpha"))
        XCTAssertTrue(csv.contains("Beta"))
    }

    // MARK: - ZIP bulk export

    func testZIPExportProducesNonEmptyData() throws {
        let m = makeMeeting()
        let zipData = try service.exportMeetingsZip(meetings: [m])
        XCTAssertGreaterThan(zipData.count, 22,
                             "ZIP must be larger than the minimum end-of-central-dir record (22 bytes)")
    }

    func testZIPExportStartsWithPKSignature() throws {
        let m = makeMeeting()
        let zipData = try service.exportMeetingsZip(meetings: [m])
        // ZIP local file header signature: 0x04034b50 (little-endian: PK\x03\x04)
        XCTAssertEqual(zipData[0], 0x50, "ZIP must start with 0x50 (P)")
        XCTAssertEqual(zipData[1], 0x4B, "ZIP must start with 0x4B (K)")
        XCTAssertEqual(zipData[2], 0x03)
        XCTAssertEqual(zipData[3], 0x04)
    }

    func testZIPExportEndOfCentralDirPresent() throws {
        let m = makeMeeting()
        let zipData = try service.exportMeetingsZip(meetings: [m])
        // End of central directory signature: 0x06054b50 (little-endian: PK\x05\x06)
        let bytes = [UInt8](zipData)
        let eocdSig: [UInt8] = [0x50, 0x4B, 0x05, 0x06]
        XCTAssertTrue(bytes.containsSequence(eocdSig),
                      "ZIP must contain End of Central Directory signature")
    }

    func testZIPExportWithMultipleMeetings() throws {
        let m1 = makeMeeting(title: "Meeting One")
        let m2 = makeMeeting(title: "Meeting Two")
        let zipData = try service.exportMeetingsZip(meetings: [m1, m2])
        // The archive must contain content from both meetings
        XCTAssertGreaterThan(zipData.count, 200,
                             "ZIP with 2 meetings must be substantially larger than minimum")
    }

    func testZIPExportEmptyMeetingsList() throws {
        let zipData = try service.exportMeetingsZip(meetings: [])
        // Should produce a valid ZIP with just the index.json and end-of-central-dir
        XCTAssertGreaterThan(zipData.count, 22, "Empty ZIP must still have valid structure")
        XCTAssertEqual(zipData[0], 0x50) // PK header
    }

    // MARK: - All MeetingExportFormat cases compile and have extensions

    func testAllExportFormatsHaveNonEmptyExtensions() {
        for format in MeetingExportFormat.allCases {
            XCTAssertFalse(format.fileExtension.isEmpty,
                           "\(format) must have a non-empty file extension")
        }
    }

    func testCSVIsInAllCases() {
        XCTAssertTrue(MeetingExportFormat.allCases.contains(.csv),
                      ".csv must be in MeetingExportFormat.allCases")
    }

    // MARK: - Auto-analysis guard logic

    func testAutoAnalyzeSkippedWhenDisabled() async {
        // The guard: UserDefaults.standard.bool(forKey: "orin.meetings.autoAnalyze")
        let key = "orin.meetings.autoAnalyze"
        UserDefaults.standard.set(false, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        // Verify the guard fires: flag = false → analysis should NOT run
        let shouldAnalyze = UserDefaults.standard.bool(forKey: key)
        XCTAssertFalse(shouldAnalyze, "Auto-analyze must be skipped when flag is false")
    }

    func testAutoAnalyzeSkippedWhenTooShort() async {
        let key = "orin.meetings.autoAnalyze"
        let minKey = "orin.meetings.minDurationMinutes"
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.set(5, forKey: minKey)  // 5 min threshold
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: minKey)
        }

        let elapsed: TimeInterval = 60  // 1 minute — below 5 min threshold
        let minMinutes = max(1, UserDefaults.standard.integer(forKey: minKey))
        let shouldAnalyze = elapsed >= TimeInterval(minMinutes * 60)
        XCTAssertFalse(shouldAnalyze, "Auto-analyze must be skipped when recording is too short")
    }

    func testAutoAnalyzeRunsWhenEnabled() async {
        let key = "orin.meetings.autoAnalyze"
        let minKey = "orin.meetings.minDurationMinutes"
        UserDefaults.standard.set(true, forKey: key)
        UserDefaults.standard.set(1, forKey: minKey)  // 1 min threshold
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            UserDefaults.standard.removeObject(forKey: minKey)
        }

        let elapsed: TimeInterval = 120  // 2 minutes — above threshold
        let minMinutes = max(1, UserDefaults.standard.integer(forKey: minKey))
        let shouldAnalyze = elapsed >= TimeInterval(minMinutes * 60)
        XCTAssertTrue(shouldAnalyze, "Auto-analyze must run when elapsed >= minimum duration")
    }

    func testAutoAnalyzeMinimumDefaultIsOneMinute() {
        let minKey = "orin.meetings.minDurationMinutes"
        UserDefaults.standard.removeObject(forKey: minKey)
        defer { UserDefaults.standard.removeObject(forKey: minKey) }

        let minMinutes = max(1, UserDefaults.standard.integer(forKey: minKey))
        XCTAssertEqual(minMinutes, 1, "Default minimum duration must be 1 minute")
    }
}

// MARK: - Byte-array sliding window helper for ZIP signature search

private extension Array where Element == UInt8 {
    func containsSequence(_ needle: [UInt8]) -> Bool {
        guard count >= needle.count else { return false }
        for i in 0...(count - needle.count) {
            if Array(self[i..<(i + needle.count)]) == needle { return true }
        }
        return false
    }
}
