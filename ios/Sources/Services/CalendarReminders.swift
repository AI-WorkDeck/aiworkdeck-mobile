// SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
// SPDX-License-Identifier: AGPL-3.0-or-later
import UserNotifications
import Observation

@MainActor @Observable
final class CalendarReminders: NSObject, UNUserNotificationCenterDelegate {
    static let shared = CalendarReminders()
    var selectedEventID: String?
    private(set) var enabled = UserDefaults.standard.bool(forKey: "personal.calendar.reminders")
    private var generation = UUID()
    private var queue: Task<Void, Never>?
    private let prefix = "calendar."

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    func allow() async -> Bool {
        let allowed = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        enabled = allowed
        UserDefaults.standard.set(allowed, forKey: "personal.calendar.reminders")
        if allowed { await CalendarRemotePush.shared.prepare() }
        return allowed
    }
    static func upcoming(_ events: [PersonalCalendarEvent], now: Date = Date()) -> [PersonalCalendarEvent] {
        events.filter { $0.status == "OPEN" && ($0.reminderDate ?? .distantPast) > now }
            .sorted { $0.reminderDate! < $1.reminderDate! }.prefix(50).map { $0 }
    }
    // Keep notification synchronization ordered without holding page loading or
    // account settings open while the system notification service responds.
    func replace(_ events: [PersonalCalendarEvent]) {
        let previous = queue
        let version = UUID(); generation = version
        let work = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, self.generation == version else { return }
            await self.apply(events, version: version)
        }
        queue = work
    }
    private func apply(_ events: [PersonalCalendarEvent], version: UUID) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        guard generation == version else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        guard enabled, !CalendarRemotePush.shared.registered else { return }
        for event in Self.upcoming(events) {
            guard generation == version else { return }
            let content = UNMutableNotificationContent()
            content.body = tr("personal.reminders")
            content.sound = .default
            content.userInfo = ["calendarEventId": event.id]
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .timeZone], from: event.reminderDate!)
            try? await center.add(UNNotificationRequest(identifier: prefix + event.id, content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)))
        }
        // A logout can occur while the last add awaits the notification service.
        if generation != version { await removeCalendarNotifications() }
    }
    private func removeCalendarNotifications() async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter { $0.hasPrefix(prefix) })
        let delivered = await center.deliveredNotifications()
        center.removeDeliveredNotifications(withIdentifiers: delivered.map { $0.request.identifier }.filter { $0.hasPrefix(prefix) })
    }
    func clear() {
        CalendarRemotePush.shared.clear()
        generation = UUID(); enabled = false; selectedEventID = nil
        UserDefaults.standard.removeObject(forKey: "personal.calendar.reminders")
        let previous = queue
        queue = Task { @MainActor [weak self] in
            await previous?.value
            await self?.removeCalendarNotifications()
        }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let eventID = (info["calendarEventId"] ?? info["eventId"]) as? String else { return }
        await MainActor.run { self.selectedEventID = eventID }
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        (notification.request.identifier.hasPrefix("calendar.") || notification.request.content.userInfo["eventId"] != nil) ? [.banner, .sound] : [.banner]
    }
}
