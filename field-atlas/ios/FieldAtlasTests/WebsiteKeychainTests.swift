import XCTest
import Security
@testable import FieldAtlas

final class WebsiteKeychainTests: XCTestCase {
    func testCredentialsAreStoredUpdatedAndRemovedInRealKeychain() throws {
        let session = UUID().uuidString
        setenv("FIELD_ATLAS_TEST_SESSION", session, 1)
        let storage = WebsiteKeychain()
        defer { try? storage.clear(); unsetenv("FIELD_ATLAS_TEST_SESSION") }
        XCTAssertNil(try storage.read())
        let first = StaffAccountCredentials(accessToken: "test-only-first-" + session,
            tokenType: "Bearer", expiresAt: "2030-01-01T00:00:00Z", expiresIn: 3600, clientID: "test-only")
        try storage.save(first)
        XCTAssertEqual(try storage.read()?.accessToken, first.accessToken)

        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "ru.archiverf.fieldatlas.website-account.test." + session,
            kSecAttrAccount as String: "archiverf.ru", kSecReturnAttributes as String: true]
        var result: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &result), errSecSuccess)
        let attributes = try XCTUnwrap(result as? [String: Any])
        XCTAssertEqual(attributes[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNotEqual(attributes[kSecAttrSynchronizable as String] as? Bool, true)

        let changed = StaffAccountCredentials(accessToken: "test-only-updated-" + session,
            tokenType: "Bearer", expiresAt: first.expiresAt, expiresIn: 3600, clientID: "test-only")
        try storage.save(changed)
        XCTAssertEqual(try storage.read()?.accessToken, changed.accessToken)
        try storage.clear()
        XCTAssertNil(try storage.read())
        XCTAssertNoThrow(try storage.clear())
    }
}
