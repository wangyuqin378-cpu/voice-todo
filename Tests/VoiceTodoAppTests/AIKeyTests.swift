import XCTest
import VoiceTodoCore
@testable import VoiceTodoApp

final class AIKeyTests: XCTestCase {
    func testReferencedKeyCannotFollowAnEditedProviderEndpoint() throws {
        let suite = "VoiceTodo-QA-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: file) }
        try "DEEPSEEK_API_KEY: 'fake-qa-key-not-a-credential'\n".write(to: file, atomically: true, encoding: .utf8)
        defaults.set(file.path, forKey: AIKey.referenceKey)
        XCTAssertEqual(try AIKey.read(configuration: .init(baseURL: "https://api.deepseek.com", model: "deepseek-flash"), defaults: defaults), "fake-qa-key-not-a-credential")
        for endpoint in ["https://other.example", "https://api.deepseek.com.example", "http://api.deepseek.com"] {
            XCTAssertThrowsError(try AIKey.read(configuration: .init(baseURL: endpoint, model: "deepseek-flash"), defaults: defaults))
        }
        try "DEEPSEEK_API_KEY: a\nDEEPSEEK_API_KEY: b\n".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try AIKey.fileKey(path: file.path))
    }
}
