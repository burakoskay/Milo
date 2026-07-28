import Foundation
import XCTest
@testable import Milo

final class CloudSignatureManagerTests: XCTestCase {

    func testWildcardMatch_exactMatch() {
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "com.apple.Safari", value: "com.apple.Safari"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "com.apple.Safari", value: "com.apple.Safar"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "com.apple.Safari", value: "com.apple.Safari2"))
    }

    func testWildcardMatch_singleWildcard() {
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "com.apple.*", value: "com.apple.Safari"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "com.apple.*", value: "com.apple."))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "com.apple.*", value: "org.mozilla.Firefox"))
    }

    func testWildcardMatch_multipleWildcards() {
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "com.*.Saf*", value: "com.apple.Safari"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "*.*.*", value: "a.b.c"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "*.*.*", value: "com.apple.Safari"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "*.*.*", value: "com_apple_Safari"))
    }

    func testWildcardMatch_wildcardAtStart() {
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "*.Safari", value: "com.apple.Safari"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "*.Safari", value: ".Safari"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "*.Safari", value: "com.apple.Safari2"))
    }

    func testWildcardMatch_wildcardInMiddle() {
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "com.*.Safari", value: "com.apple.Safari"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "com.*.Safari", value: "com..Safari"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "com.*.Safari", value: "org.apple.Safari"))
    }

    func testWildcardMatch_onlyWildcards() {
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "*", value: "anything"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "*", value: ""))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "**", value: "anything"))
    }

    func testWildcardMatch_emptyPatternAndValue() {
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "", value: ""))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "", value: "test"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "test", value: ""))
    }

    func testWildcardMatch_regexMetacharacters() {
        // Test that literal periods are treated as periods, not as any character
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "a.b", value: "a.b"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "a.b", value: "a_b"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "a.b", value: "acb"))

        // Test other regex metacharacters
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "a[b]c", value: "a[b]c"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "a[b]c", value: "abc"))

        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "a+b", value: "a+b"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "a+b", value: "aab"))

        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "a(b)c", value: "a(b)c"))
        XCTAssertFalse(CloudSignatureManager.wildcardMatch(pattern: "a(b)c", value: "abc"))

        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "a$b^c", value: "a$b^c"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "a\\b", value: "a\\b"))
        XCTAssertTrue(CloudSignatureManager.wildcardMatch(pattern: "a|b", value: "a|b"))
    }
}
