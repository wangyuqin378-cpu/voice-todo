import Foundation
import UserNotifications
import VoiceTodoCore

@MainActor protocol TaskNotifications: AnyObject {
    var onStatus: ((String?) -> Void)? { get set }
    var onOpen: (() -> Void)? { get set }
    func requestPermission() async -> Bool
    func authorization() async -> UNAuthorizationStatus
    func reconcile(_ tasks: [TodoItem]) async
}

@MainActor protocol NotificationCenterClient: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }
    func requestPermission() async -> Bool
    func authorization() async -> UNAuthorizationStatus
    func pending() async -> [UNNotificationRequest]
    func deliveredIDs() async -> Set<String>
    func removePending(_ ids: [String])
    func removeDelivered(_ ids: [String])
    func add(_ request: UNNotificationRequest) async throws
}

@MainActor private final class SystemNotificationCenter: NotificationCenterClient {
    private let center = UNUserNotificationCenter.current()
    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }
    func requestPermission() async -> Bool { (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false }
    func authorization() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func pending() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func deliveredIDs() async -> Set<String> { Set(await center.deliveredNotifications().map { $0.request.identifier }) }
    func removePending(_ ids: [String]) { center.removePendingNotificationRequests(withIdentifiers: ids) }
    func removeDelivered(_ ids: [String]) { center.removeDeliveredNotifications(withIdentifiers: ids) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
}

@MainActor final class NotificationService: NSObject, UNUserNotificationCenterDelegate, TaskNotifications {
    private let center: any NotificationCenterClient
    private let defaults: UserDefaults
    private var delivered: Set<String>
    private var reconciling = false
    private var nextTasks: [TodoItem]?
    private var latestReminderIDs: Set<String> = []
    var onStatus: ((String?) -> Void)?
    var onOpen: (() -> Void)?
    init(center: (any NotificationCenterClient)? = nil, defaults: UserDefaults = .standard) {
        self.center = center ?? SystemNotificationCenter(); self.defaults = defaults
        delivered = Set(defaults.stringArray(forKey: "notification.delivered") ?? [])
        super.init(); self.center.delegate = self
    }
    func requestPermission() async -> Bool {
        await center.requestPermission()
    }
    func authorization() async -> UNAuthorizationStatus { await center.authorization() }
    func reconcile(_ tasks: [TodoItem]) async {
        latestReminderIDs = Set(tasks.filter { !$0.isCompleted && $0.reminderAt != nil }.map(ReminderPlanner.identifier))
        // Retract known alarms immediately. Cancellation must not wait behind
        // a slow notification-center read or an older reconciliation pass.
        let schedules = defaults.dictionary(forKey: "notification.scheduled") as? [String: Double] ?? [:]
        let obsolete = schedules.keys.filter { !latestReminderIDs.contains($0) }
        if !obsolete.isEmpty {
            center.removePending(obsolete); center.removeDelivered(obsolete)
            defaults.set(schedules.filter { latestReminderIDs.contains($0.key) }, forKey: "notification.scheduled")
        }
        nextTasks = tasks
        guard !reconciling else { return }
        reconciling = true
        defer { reconciling = false }
        while let snapshot = nextTasks {
            nextTasks = nil
            await reconcileOnce(snapshot)
        }
    }
    private func reconcileOnce(_ tasks: [TodoItem]) async {
        let pending = await center.pending()
        guard nextTasks == nil else { return }
        let shown = await center.deliveredIDs()
        guard nextTasks == nil else { return }
        delivered.formUnion(shown)
        let status = await authorization()
        guard nextTasks == nil else { return }
        let allowed = status == .authorized || status == .provisional
        // Remember elapsed requests across restarts even if a user dismissed the banner.
        let schedules = defaults.dictionary(forKey: "notification.scheduled") as? [String: Double] ?? [:]
        let pendingIDs = Set(pending.map(\.identifier))
        let pendingByID = Dictionary(uniqueKeysWithValues: pending.map { ($0.identifier, $0) })
        for (id, timestamp) in schedules where allowed && timestamp <= Date.now.timeIntervalSince1970 && !pendingIDs.contains(id) {
            delivered.insert(id)
        }
        defaults.set(Array(delivered), forKey: "notification.delivered")
        let valid = Set(tasks.filter { !$0.isCompleted && $0.reminderAt != nil }.map(ReminderPlanner.identifier))
        center.removeDelivered(shown.filter { $0.hasPrefix("todo.") && !valid.contains($0) })
        guard allowed else {
            // A denied notification is not a delivered one. Forget its scheduling
            // receipt so enabling notifications can catch it up exactly once.
            center.removePending(pendingIDs.filter { $0.hasPrefix("todo.") })
            defaults.removeObject(forKey: "notification.scheduled")
            onStatus?("通知尚未开启，已保存的任务目前不能弹出系统提醒。")
            return
        }
        // Re-select the earliest queue on every change. Keeping 60 far-future
        // requests must not prevent a newly added imminent reminder from entering.
        let plans = Array(ReminderPlanner.plans(tasks: tasks, delivered: delivered, scheduled: [], now: .now).prefix(60))
        let desired = Set(plans.map(\.identifier))
        center.removePending(pendingIDs.filter { $0.hasPrefix("todo.") && !desired.contains($0) })
        var scheduleTimes = schedules.filter { desired.contains($0.key) }
        defer {
            // An add may suspend while a task is completed/cancelled. Keep only
            // receipts that still belong to the latest workspace, even on return.
            defaults.set(scheduleTimes.filter { latestReminderIDs.contains($0.key) }, forKey: "notification.scheduled")
        }
        var issue: String?
        for plan in plans {
            guard nextTasks == nil else { return }
            var fireAt = plan.fireAt
            if let existing = pendingByID[plan.identifier] {
                guard existing.content.body != plan.title else { continue }
                // Replace only a still-future request, using the same ID and
                // deadline. A rename must not replay an elapsed/delivered alarm.
                fireAt = schedules[plan.identifier].map(Date.init(timeIntervalSince1970:)) ?? plan.fireAt
                guard fireAt > .now, schedules[plan.identifier] != nil || !plan.overdue else { continue }
            }
            let content = UNMutableNotificationContent()
            content.title = plan.overdue ? "补发提醒" : "随口清单"
            content.body = plan.title; content.sound = .default
            content.userInfo = ["taskID": plan.taskID]
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, fireAt.timeIntervalSinceNow), repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: plan.identifier, content: content, trigger: trigger))
                if latestReminderIDs.contains(plan.identifier) {
                    scheduleTimes[plan.identifier] = fireAt.timeIntervalSince1970
                } else {
                    // The in-flight add cannot be cancelled through UN's API.
                    // Retract its result before any further asynchronous reads.
                    center.removePending([plan.identifier]); center.removeDelivered([plan.identifier])
                    scheduleTimes.removeValue(forKey: plan.identifier)
                }
            } catch { issue = "有提醒未能安排，请检查系统通知设置。" }
        }
        guard nextTasks == nil else { return }
        let remaining = tasks.filter { !$0.isCompleted && $0.reminderAt != nil && !delivered.contains(ReminderPlanner.identifier(for: $0)) }.count
        onStatus?(issue ?? (remaining > plans.count ? "提醒较多，已优先安排最近的 60 条；请保持应用运行以继续安排后续提醒。" : nil))
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        Task { @MainActor in
            self.delivered.insert(notification.request.identifier)
            self.defaults.set(Array(self.delivered), forKey: "notification.delivered")
        }
        completionHandler([.banner, .sound, .list])
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in self.onOpen?() }; completionHandler()
    }
}
