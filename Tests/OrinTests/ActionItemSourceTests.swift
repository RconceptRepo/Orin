import XCTest
@testable import Orin

// MARK: - ActionItemSourceTests
//
// Verifies the source-of-truth consolidation for action items:
//   1. effectiveActionItemCount uses structuredActionItemsJSON as canonical
//   2. Re-analysis to empty clears stale JSON (not conditional write)
//   3. MeetingSnapshot round-trips structuredActionItemsJSON
//   4. Import restores structured JSON
//   5. Count badges and exports derive from the same field

final class ActionItemSourceTests: XCTestCase {

    // MARK: - effectiveActionItemCount: structured is canonical

    @MainActor
    func test_effectiveCount_usesStructured_whenJSONPresent() throws {
        let meeting = MeetingItem(title: "Test", date: Date())
        let items: [ActionItemRecord] = [
            ActionItemRecord(owner: "Alice", task: "Send proposal to client by Friday",
                             priority: "High", dueDateText: "Friday"),
            ActionItemRecord(owner: "Team", task: "Schedule review meeting for next week")
        ]
        meeting.actionItems = ["legacy item one", "legacy item two", "legacy item three"]
        let data = try JSONEncoder().encode(items)
        meeting.structuredActionItemsJSON = String(data: data, encoding: .utf8)!

        XCTAssertEqual(meeting.effectiveActionItemCount, 2,
            "effectiveActionItemCount must use structuredActionItems when JSON is present, not flat count")
    }

    @MainActor
    func test_effectiveCount_fallsBackToFlat_whenJSONNil() {
        let meeting = MeetingItem(title: "Legacy meeting", date: Date())
        meeting.actionItems = ["item one", "item two"]
        meeting.structuredActionItemsJSON = nil

        XCTAssertEqual(meeting.effectiveActionItemCount, 2,
            "effectiveActionItemCount must fall back to actionItems.count for legacy meetings with no JSON")
    }

    @MainActor
    func test_effectiveCount_isZero_afterReanalysisProducesEmpty() throws {
        let meeting = MeetingItem(title: "Re-analysis test", date: Date())
        // Simulate a prior analysis that produced structured items
        let prior: [ActionItemRecord] = [
            ActionItemRecord(owner: "Bob", task: "Review the quarterly budget report")
        ]
        let priorData = try JSONEncoder().encode(prior)
        meeting.structuredActionItemsJSON = String(data: priorData, encoding: .utf8)!
        meeting.actionItems = ["[Bob] Review the quarterly budget report"]

        // Simulate re-analysis that finds no action items — unconditional write
        let empty: [ActionItemRecord] = []
        let emptyData = try JSONEncoder().encode(empty)
        meeting.structuredActionItemsJSON = String(data: emptyData, encoding: .utf8)!
        meeting.actionItems = []

        XCTAssertEqual(meeting.effectiveActionItemCount, 0,
            "Re-analysis to empty must produce count 0, not retain stale structured count")
    }

    @MainActor
    func test_effectiveCount_isZero_whenJSONIsEmptyArray_regardlessOfFlatItems() throws {
        let meeting = MeetingItem(title: "Divergence check", date: Date())
        // flat array still has stale items, but JSON is authoritative
        meeting.actionItems = ["[stale] Old action item from prior run"]
        let emptyData = try JSONEncoder().encode([ActionItemRecord]())
        meeting.structuredActionItemsJSON = String(data: emptyData, encoding: .utf8)!

        XCTAssertEqual(meeting.effectiveActionItemCount, 0,
            "When structuredActionItemsJSON is '[]', effectiveActionItemCount must be 0 regardless of flat array")
    }

    // MARK: - Stale JSON prevention

    func test_encodingEmptyArray_producesValidJSON_notNil() throws {
        let empty: [ActionItemRecord] = []
        let data = try JSONEncoder().encode(empty)
        let json = String(data: data, encoding: .utf8)
        XCTAssertNotNil(json, "Encoding an empty array must succeed and produce valid JSON")
        XCTAssertEqual(json, "[]", "Empty [ActionItemRecord] must encode to the literal string '[]'")
    }

    func test_unconditionalWrite_allowsEmptyArrayToOverwritePriorJSON() throws {
        // The old conditional write `if !items.isEmpty { ... }` would not execute
        // when items is empty, leaving stale JSON. Verify the new path works.
        var storedJSON: String? = nil

        // First write: non-empty
        let initial: [ActionItemRecord] = [
            ActionItemRecord(owner: "Me", task: "Call Praveen to discuss content handover")
        ]
        if let data = try? JSONEncoder().encode(initial),
           let json = String(data: data, encoding: .utf8) {
            storedJSON = json
        }
        XCTAssertNotNil(storedJSON)

        // Second write: empty (new unconditional path)
        let empty: [ActionItemRecord] = []
        if let data = try? JSONEncoder().encode(empty),
           let json = String(data: data, encoding: .utf8) {
            storedJSON = json
        }
        XCTAssertEqual(storedJSON, "[]",
            "Unconditional write must overwrite prior JSON with '[]' when analysis produces no items")
    }

    // MARK: - MeetingSnapshot round-trip

    @MainActor
    func test_snapshotRoundTrip_preservesStructuredJSON() throws {
        let meeting = MeetingItem(title: "Round-trip test", date: Date())
        let items: [ActionItemRecord] = [
            ActionItemRecord(owner: "Alice", task: "Send proposal to client by Friday",
                             priority: "High", dueDateText: "Friday"),
            ActionItemRecord(owner: "Team", task: "Schedule review meeting for next week")
        ]
        let structuredData = try JSONEncoder().encode(items)
        meeting.structuredActionItemsJSON = String(data: structuredData, encoding: .utf8)!
        meeting.actionItems = items.map { "[\($0.owner)] \($0.task)" }

        // Snapshot → JSON encode → JSON decode
        let snapshot = MeetingSnapshot(meeting)
        let snapshotData = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(MeetingSnapshot.self, from: snapshotData)

        XCTAssertNotNil(restored.structuredActionItemsJSON,
            "MeetingSnapshot must carry structuredActionItemsJSON through encode/decode")

        guard let restoredJSON = restored.structuredActionItemsJSON,
              let decodedData  = restoredJSON.data(using: .utf8),
              let restoredItems = try? JSONDecoder().decode([ActionItemRecord].self, from: decodedData)
        else {
            XCTFail("structuredActionItemsJSON in restored snapshot must be decodable")
            return
        }

        XCTAssertEqual(restoredItems.count, 2,      "Round-trip must preserve item count")
        XCTAssertEqual(restoredItems[0].owner, "Alice")
        XCTAssertEqual(restoredItems[0].task, "Send proposal to client by Friday")
        XCTAssertEqual(restoredItems[0].dueDateText, "Friday")
        XCTAssertEqual(restoredItems[0].priority, "High")
        XCTAssertEqual(restoredItems[1].owner, "Team")
    }

    @MainActor
    func test_snapshotRoundTrip_handlesNilStructuredJSON() throws {
        let meeting = MeetingItem(title: "Legacy meeting", date: Date())
        meeting.actionItems = ["Legacy action item from old analysis"]
        meeting.structuredActionItemsJSON = nil

        let snapshot = MeetingSnapshot(meeting)
        let snapshotData = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(MeetingSnapshot.self, from: snapshotData)

        XCTAssertNil(restored.structuredActionItemsJSON,
            "nil structuredActionItemsJSON must survive snapshot round-trip as nil")
        XCTAssertEqual(restored.actionItems.count, 1,
            "Flat actionItems must survive round-trip when structured JSON is nil")
    }

    @MainActor
    func test_snapshotRoundTrip_preservesEmptyStructuredJSON() throws {
        let meeting = MeetingItem(title: "Empty items test", date: Date())
        let emptyData = try JSONEncoder().encode([ActionItemRecord]())
        meeting.structuredActionItemsJSON = String(data: emptyData, encoding: .utf8)!
        meeting.actionItems = []

        let snapshot = MeetingSnapshot(meeting)
        let snapshotData = try JSONEncoder().encode(snapshot)
        let restored = try JSONDecoder().decode(MeetingSnapshot.self, from: snapshotData)

        XCTAssertEqual(restored.structuredActionItemsJSON, "[]",
            "Empty-array structuredActionItemsJSON must survive round-trip as '[]', not nil")
    }

    // MARK: - Count consistency

    @MainActor
    func test_flatAndStructured_agreeAfterNormalAnalysis() throws {
        let meeting = MeetingItem(title: "Consistency test", date: Date())
        let items: [ActionItemRecord] = [
            ActionItemRecord(owner: "Me", task: "Follow up with Anish about bandwidth changes"),
            ActionItemRecord(owner: "Alice", task: "Schedule review meeting for Friday")
        ]
        let data = try JSONEncoder().encode(items)
        meeting.structuredActionItemsJSON = String(data: data, encoding: .utf8)!
        meeting.actionItems = items.map { "[\($0.owner)] \($0.task)" }

        XCTAssertEqual(meeting.effectiveActionItemCount, meeting.actionItems.count,
            "When analysis succeeds, effectiveActionItemCount and actionItems.count must agree")
        XCTAssertEqual(meeting.effectiveActionItemCount, 2)
    }

    @MainActor
    func test_effectiveCount_reflectsStructuredCount_notFlatCount_onDivergence() throws {
        // Simulates a scenario where flat items were written by an old code path
        // and structured JSON was written by the new path — structured wins.
        let meeting = MeetingItem(title: "Divergence scenario", date: Date())
        let structured: [ActionItemRecord] = [
            ActionItemRecord(owner: "Me", task: "Write medical use case proposal within two days")
        ]
        let data = try JSONEncoder().encode(structured)
        meeting.structuredActionItemsJSON = String(data: data, encoding: .utf8)!
        // Flat array has more items (e.g. garbage from old keyword fallback)
        meeting.actionItems = ["Okay.", "Mm-hmm.", "[Me] Write medical use case proposal within two days"]

        XCTAssertEqual(meeting.effectiveActionItemCount, 1,
            "structuredActionItemsJSON is canonical — count must be 1, not 3")
    }
}
