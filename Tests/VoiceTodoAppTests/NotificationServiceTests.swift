import XCTest
import UserNotifications
import VoiceTodoCore
@testable import VoiceTodoApp

@MainActor private final class TestNotificationCenter: NotificationCenterClient {
    weak var delegate: UNUserNotificationCenterDelegate?
    var status: UNAuthorizationStatus = .authorized
    var requests: [String: UNNotificationRequest] = [:]
    var delivered: Set<String> = []
    var added: [String] = []
    var shouldFail = false
    func requestPermission() async -> Bool { status == .authorized }
    func authorization() async -> UNAuthorizationStatus { status }
    func pending() async -> [UNNotificationRequest] { Array(requests.values) }
    func deliveredIDs() async -> Set<String> { delivered }
    func removePending(_ ids: [String]) { ids.forEach { requests.removeValue(forKey: $0) } }
    func removeDelivered(_ ids: [String]) { delivered.subtract(ids) }
    func add(_ request: UNNotificationRequest) async throws {
        if shouldFail { throw UserFacingError("test failure") }
        added.append(request.identifier); requests[request.identifier] = request
    }
}

@MainActor final class NotificationServiceTests: XCTestCase {
    private func fixture() -> (TestNotificationCenter, UserDefaults, NotificationService) {
        let name = "voice-todo-notifications-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let center = TestNotificationCenter()
        return (center, defaults, NotificationService(center: center, defaults: defaults))
    }
    func testNewUrgentReminderDisplacesLastOfFullQueue() async {
        let (center, _, service) = fixture()
        let future = (1...60).map { TodoItem(id: "future-\($0)", title: "合成事项 \($0)", reminderAt: .now.addingTimeInterval(Double($0) * 86400)) }
        await service.reconcile(future)
        XCTAssertEqual(center.requests.count, 60)
        let urgent = TodoItem(id: "urgent", title: "即将开始", reminderAt: .now.addingTimeInterval(30))
        await service.reconcile(future + [urgent])
        XCTAssertEqual(center.requests.count, 60)
        XCTAssertNotNil(center.requests[ReminderPlanner.identifier(for: urgent)])
        XCTAssertNil(center.requests[ReminderPlanner.identifier(for: future.last!)])
        XCTAssertEqual(center.added.count, 61)
        await service.reconcile(future + [urgent])
        XCTAssertEqual(center.added.count, 61, "Reconciliation must preserve existing requests")
    }
    func testDeniedPermissionDoesNotMarkMissingAlarmDelivered() async {
        let (center, defaults, service) = fixture()
        let item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(-60))
        let id = ReminderPlanner.identifier(for: item)
        defaults.set([id: Date.now.addingTimeInterval(-30).timeIntervalSince1970], forKey: "notification.scheduled")
        center.status = .denied
        var warning: String?
        service.onStatus = { warning = $0 }
        await service.reconcile([item])
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertFalse((defaults.stringArray(forKey: "notification.delivered") ?? []).contains(id))
        XCTAssertNotNil(warning)
        center.status = .authorized
        await service.reconcile([item])
        XCTAssertNotNil(center.requests[id])
        XCTAssertEqual(center.requests[id]?.content.title, "补发提醒")
        XCTAssertNil(warning)
        await service.reconcile([item])
        XCTAssertEqual(center.added, [id])
    }
    func testCompletionAndCancellationRemovePendingAndShownReminders() async {
        let (center, _, service) = fixture()
        var item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(60))
        let id = ReminderPlanner.identifier(for: item)
        await service.reconcile([item])
        center.delivered.insert(id)
        item.completedAt = .now
        await service.reconcile([item])
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertTrue(center.delivered.isEmpty)
        item.completedAt = nil; item.reminderRevision = UUID().uuidString
        await service.reconcile([item])
        XCTAssertEqual(center.requests.count, 1)
        await service.reconcile([])
        XCTAssertTrue(center.requests.isEmpty)
    }
    func testSchedulingFailureRemainsRetryable() async {
        let (center, defaults, service) = fixture()
        let item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(60))
        var warning: String?
        service.onStatus = { warning = $0 }
        center.shouldFail = true
        await service.reconcile([item])
        XCTAssertNotNil(warning)
        XCTAssertTrue((defaults.dictionary(forKey: "notification.scheduled") ?? [:]).isEmpty)
        center.shouldFail = false
        await service.reconcile([item])
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertNil(warning)
    }
    func testDeliveredReceiptPreventsDuplicateAcrossServiceRestart() async {
        let (center, defaults, service) = fixture()
        let item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(-60))
        center.delivered = [ReminderPlanner.identifier(for: item)]
        await service.reconcile([item])
        center.delivered = []
        let restarted = NotificationService(center: center, defaults: defaults)
        await restarted.reconcile([item])
        XCTAssertTrue(center.requests.isEmpty)
    }
    func testNewInstallUsesLocalSpeechAndPreservesExplicitOldChoice() {
        let (_, defaults, _) = fixture()
        XCTAssertTrue(AppSettings(defaults: defaults).fnLocalSpeech)
        defaults.set(false, forKey: "inputMethod.localSpeech")
        XCTAssertFalse(AppSettings(defaults: defaults).fnLocalSpeech)
    }
}
