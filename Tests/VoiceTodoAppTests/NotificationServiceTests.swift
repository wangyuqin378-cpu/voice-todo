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
    var holdPending = false
    var pendingGate: CheckedContinuation<Void, Never>?
    var holdAdd = false
    var addGate: CheckedContinuation<Void, Never>?

    func requestPermission() async -> Bool { status == .authorized }
    func authorization() async -> UNAuthorizationStatus { status }
    func pending() async -> [UNNotificationRequest] {
        if holdPending { await withCheckedContinuation { pendingGate = $0 } }
        return Array(requests.values)
    }
    func deliveredIDs() async -> Set<String> { delivered }
    func removePending(_ ids: [String]) { ids.forEach { requests.removeValue(forKey: $0) } }
    func removeDelivered(_ ids: [String]) { delivered.subtract(ids) }
    func add(_ request: UNNotificationRequest) async throws {
        if shouldFail { throw UserFacingError("test failure") }
        if holdAdd { await withCheckedContinuation { addGate = $0 } }
        added.append(request.identifier); requests[request.identifier] = request
    }
}

@MainActor private final class SlowPermissionNotifications: TaskNotifications {
    var onStatus: ((String?) -> Void)?
    var onOpen: (() -> Void)?
    var tasks: [TodoItem] = []
    var permissionGate: CheckedContinuation<Void, Never>?
    func requestPermission() async -> Bool { true }
    func authorization() async -> UNAuthorizationStatus {
        await withCheckedContinuation { permissionGate = $0 }
        return .authorized
    }
    func reconcile(_ tasks: [TodoItem]) async { self.tasks = tasks }
}

@MainActor final class NotificationServiceTests: XCTestCase {
    private func fixture() -> (TestNotificationCenter, UserDefaults, NotificationService) {
        let name = "voice-todo-notifications-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let center = TestNotificationCenter()
        return (center, defaults, NotificationService(center: center, defaults: defaults))
    }
    private func settle(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Notification operation did not reach its controlled suspension")
    }
    func testCompletionDuringSystemReadNeverAddsTheObsoleteReminder() async throws {
        let (center, _, service) = fixture()
        var item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(-60))
        center.holdPending = true
        let operation = Task { await service.reconcile([item]) }
        try await settle { center.pendingGate != nil }
        item.completedAt = .now
        await service.reconcile([item])
        center.holdPending = false; center.pendingGate?.resume(); center.pendingGate = nil
        await operation.value
        XCTAssertTrue(center.added.isEmpty, "A completed task must not be submitted even temporarily")
        XCTAssertTrue(center.requests.isEmpty)
    }
    func testCancellationDuringAddRetractsBeforeTheNextSystemRead() async throws {
        let (center, defaults, service) = fixture()
        let item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(-60))
        let id = ReminderPlanner.identifier(for: item)
        center.holdAdd = true
        let operation = Task { await service.reconcile([item]) }
        try await settle { center.addGate != nil }
        await service.reconcile([])
        center.holdPending = true; center.holdAdd = false
        center.addGate?.resume(); center.addGate = nil
        try await settle { center.pendingGate != nil }
        XCTAssertNil(center.requests[id], "Do not wait for another potentially slow system read to retract a cancelled reminder")
        XCTAssertNil((defaults.dictionary(forKey: "notification.scheduled") as? [String: Double])?[id])
        center.holdPending = false; center.pendingGate?.resume(); center.pendingGate = nil
        await operation.value
    }
    func testLatestWorkspaceWinsWhenCompletionIsUndoneWhileScheduling() async throws {
        let (center, _, service) = fixture()
        let item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(60))
        center.holdPending = true
        let operation = Task { await service.reconcile([item]) }
        try await settle { center.pendingGate != nil }
        var complete = item; complete.completedAt = .now
        await service.reconcile([complete])
        await service.reconcile([item])
        center.holdPending = false; center.pendingGate?.resume(); center.pendingGate = nil
        await operation.value
        XCTAssertEqual(center.added, [ReminderPlanner.identifier(for: item)])
        XCTAssertEqual(center.requests.count, 1)
    }
    func testExistingReminderIsCancelledWhileEarlierReconciliationIsSuspended() async throws {
        let (center, defaults, service) = fixture()
        let item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(60))
        let id = ReminderPlanner.identifier(for: item)
        await service.reconcile([item])
        center.holdPending = true
        let operation = Task { await service.reconcile([item]) }
        try await settle { center.pendingGate != nil }
        await service.reconcile([])
        XCTAssertNil(center.requests[id])
        XCTAssertNil((defaults.dictionary(forKey: "notification.scheduled") as? [String: Double])?[id])
        center.holdPending = false; center.pendingGate?.resume(); center.pendingGate = nil
        await operation.value
        XCTAssertEqual(center.added, [id])
    }
    func testManualCompletionSynchronizesReminderWithoutWaitingForPermissionRefresh() async throws {
        let (_, defaults, _) = fixture()
        let repository = try Repository(inMemory: true)
        let item = TodoItem(title: "合成事项", reminderAt: .now.addingTimeInterval(60))
        try repository.save(.init(tasks: [item]))
        let notifications = SlowPermissionNotifications(); notifications.tasks = [item]
        let state = try AppState(repository: repository, settings: AppSettings(defaults: defaults), notifications: notifications, aiKeyReader: { "" })
        state.toggle(item)
        try await settle { notifications.permissionGate != nil }
        // Give queued main-actor reconciliation a turn while permission remains suspended.
        await Task.yield()
        XCTAssertTrue(try XCTUnwrap(try repository.load().tasks.first).isCompleted)
        XCTAssertTrue(try XCTUnwrap(notifications.tasks.first).isCompleted,
            "Cancelling the task alarm must not depend on a UI permission query")
        notifications.permissionGate?.resume(); notifications.permissionGate = nil
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
    func testRenamingUpdatesPendingContentWithoutMovingReminderOrAddingAnotherRequest() async throws {
        let (center, defaults, service) = fixture()
        var item = TodoItem(title: "旧名称", reminderAt: .now.addingTimeInterval(3600))
        let id = ReminderPlanner.identifier(for: item)
        await service.reconcile([item])
        let scheduled = try XCTUnwrap((defaults.dictionary(forKey: "notification.scheduled") as? [String: Double])?[id])
        item.title = "新名称"
        await service.reconcile([item])
        XCTAssertEqual(center.requests.count, 1)
        let request = try XCTUnwrap(center.requests[id])
        XCTAssertEqual(request.content.body, "新名称")
        XCTAssertEqual(ReminderPlanner.identifier(for: item), id)
        XCTAssertEqual((defaults.dictionary(forKey: "notification.scheduled") as? [String: Double])?[id], scheduled)
        let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
        XCTAssertEqual(trigger.timeInterval, scheduled - Date.now.timeIntervalSince1970, accuracy: 1)
        await service.reconcile([item])
        XCTAssertEqual(center.added, [id, id], "Unchanged content must not be rescheduled each time")
    }
    func testRenameFailurePreservesOriginalAlarmAndRetriesNewContent() async {
        let (center, _, service) = fixture()
        var item = TodoItem(title: "旧名称", reminderAt: .now.addingTimeInterval(3600))
        let id = ReminderPlanner.identifier(for: item)
        await service.reconcile([item])
        var warning: String?
        service.onStatus = { warning = $0 }
        item.title = "新名称"; center.shouldFail = true
        await service.reconcile([item])
        XCTAssertEqual(center.requests[id]?.content.body, "旧名称")
        XCTAssertNotNil(warning)
        center.shouldFail = false
        await service.reconcile([item])
        XCTAssertEqual(center.requests[id]?.content.body, "新名称")
        XCTAssertNil(warning)
    }
    func testRenameDoesNotResendDeliveredOrElapsedPendingAlarm() async {
        let (center, defaults, service) = fixture()
        var item = TodoItem(title: "旧名称", reminderAt: .now.addingTimeInterval(-60))
        let id = ReminderPlanner.identifier(for: item)
        await service.reconcile([item])
        defaults.set([id: Date.now.addingTimeInterval(-1).timeIntervalSince1970], forKey: "notification.scheduled")
        item.title = "新名称"
        await service.reconcile([item])
        XCTAssertEqual(center.added, [id], "An elapsed request may be delivering; do not replace it")
        center.requests = [:]; center.delivered = [id]
        await service.reconcile([item])
        XCTAssertTrue(center.requests.isEmpty)
        let restarted = NotificationService(center: center, defaults: defaults)
        center.delivered = []
        await restarted.reconcile([item])
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.added, [id])
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
