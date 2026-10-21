import UserNotifications

@MainActor
final class RecordingReminderNotification {
    private let center = UNUserNotificationCenter.current()
    private let identifier = "recording-silence"

    func requestPermission() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    func show() {
        let content = UNMutableNotificationContent()
        content.title = tr("rec.silence.title")
        content.body = tr("rec.silence.message")
        // No sound: an alert must not interrupt or be recorded by the microphone.
        center.add(UNNotificationRequest(identifier: identifier, content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
    }

    func clear() {
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
}
