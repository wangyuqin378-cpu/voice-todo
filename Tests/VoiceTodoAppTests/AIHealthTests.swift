import XCTest
import VoiceTodoCore
@testable import VoiceTodoApp

final class AIHealthTests: XCTestCase {
    func testTemporaryFailurePausesOnlyOneMinuteAndSuccessResets() {
        let now = Date(timeIntervalSince1970: 1000)
        var health = AIHealth(); health.prepare(configuration: .init(), key: "fixture")
        health.failure(URLError(.timedOut), now: now)
        XCTAssertFalse(health.canAttempt(now: now.addingTimeInterval(59)))
        XCTAssertTrue(health.canAttempt(now: now.addingTimeInterval(60)))
        health.success(); XCTAssertTrue(health.status.isEmpty)
        XCTAssertTrue(health.canAttempt(now: now))
    }
    func testCredentialOrConfigurationChangesClearPermanentPause() {
        var health = AIHealth(); var configuration = AIConfiguration()
        health.prepare(configuration: configuration, key: "fixture-a")
        health.failure(AIServiceError(.credentials, "invalid"))
        XCTAssertFalse(health.canAttempt(now: .distantFuture))
        health.prepare(configuration: configuration, key: "fixture-a")
        XCTAssertFalse(health.canAttempt())
        health.prepare(configuration: configuration, key: "fixture-b")
        XCTAssertTrue(health.canAttempt())
        health.failure(AIServiceError(.configuration, "model"))
        configuration.apiProtocol = .anthropicMessages
        health.prepare(configuration: configuration, key: "fixture-b")
        XCTAssertTrue(health.canAttempt())
    }
    func testTaskValidationFailureDoesNotDisableHealthyService() {
        var health = AIHealth(); health.prepare(configuration: .init(), key: "fixture")
        health.failure(UserFacingError("未匹配具体事项"))
        XCTAssertTrue(health.canAttempt()); XCTAssertTrue(health.status.isEmpty)
    }
    @MainActor func testProtocolSettingMigratesAndPersists() throws {
        let suite = "com.wyq.voicetodo.qa." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite)); defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.apiProtocol, .automatic)
        settings.apiProtocol = .anthropicMessages
        XCTAssertEqual(AppSettings(defaults: defaults).configuration.apiProtocol, .anthropicMessages)
    }
}
