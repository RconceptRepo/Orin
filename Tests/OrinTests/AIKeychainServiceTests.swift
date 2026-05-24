import XCTest
@testable import Orin

/// Tests run against the real Keychain. Keys are written under a unique
/// per-run account prefix so they don't collide with production data and
/// are unconditionally deleted in tearDown.
final class AIKeychainServiceTests: XCTestCase {

    private var testAccount: String!

    override func setUp() {
        super.setUp()
        testAccount = "orin-test-\(UUID().uuidString)"
    }

    override func tearDown() {
        super.tearDown()
        AIKeychainService.delete(account: testAccount)
    }

    // MARK: - Round-trip

    func testSaveAndLoad() {
        let saved = AIKeychainService.save("sk-test-key-1234", account: testAccount)
        XCTAssertTrue(saved, "Save must succeed")
        XCTAssertEqual(AIKeychainService.load(account: testAccount), "sk-test-key-1234")
    }

    func testLoadMissingKeyReturnsNil() {
        XCTAssertNil(AIKeychainService.load(account: "does-not-exist-\(UUID().uuidString)"))
    }

    func testHasKeyReturnsTrueAfterSave() {
        AIKeychainService.save("some-key", account: testAccount)
        XCTAssertTrue(AIKeychainService.hasKey(for: testAccount))
    }

    func testHasKeyReturnsFalseWhenAbsent() {
        XCTAssertFalse(AIKeychainService.hasKey(for: "no-such-account-\(UUID().uuidString)"))
    }

    // MARK: - Overwrite

    func testSavingAgainOverwritesPreviousValue() {
        AIKeychainService.save("first-value", account: testAccount)
        AIKeychainService.save("second-value", account: testAccount)
        XCTAssertEqual(AIKeychainService.load(account: testAccount), "second-value")
    }

    // MARK: - Delete

    func testDeleteRemovesKey() {
        AIKeychainService.save("to-be-deleted", account: testAccount)
        XCTAssertTrue(AIKeychainService.hasKey(for: testAccount))

        AIKeychainService.delete(account: testAccount)
        XCTAssertFalse(AIKeychainService.hasKey(for: testAccount))
        XCTAssertNil(AIKeychainService.load(account: testAccount))
    }

    func testDeleteMissingKeyDoesNotCrash() {
        // Should be a no-op with no throw.
        AIKeychainService.delete(account: "ghost-account-\(UUID().uuidString)")
    }

    // MARK: - Isolation

    func testDifferentAccountsAreIndependent() {
        let accountA = "acct-a-\(UUID().uuidString)"
        let accountB = "acct-b-\(UUID().uuidString)"
        defer {
            AIKeychainService.delete(account: accountA)
            AIKeychainService.delete(account: accountB)
        }

        AIKeychainService.save("value-a", account: accountA)
        AIKeychainService.save("value-b", account: accountB)

        XCTAssertEqual(AIKeychainService.load(account: accountA), "value-a")
        XCTAssertEqual(AIKeychainService.load(account: accountB), "value-b")

        AIKeychainService.delete(account: accountA)
        XCTAssertNil(AIKeychainService.load(account: accountA))
        XCTAssertEqual(AIKeychainService.load(account: accountB), "value-b")
    }

    // MARK: - Empty string

    func testSavingEmptyStringReturnsFalse() {
        let result = AIKeychainService.save("", account: testAccount)
        XCTAssertFalse(result, "Saving an empty key should be rejected")
        XCTAssertNil(AIKeychainService.load(account: testAccount))
    }
}
