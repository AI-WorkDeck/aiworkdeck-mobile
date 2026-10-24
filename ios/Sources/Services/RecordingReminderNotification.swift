import UserNotifications

@MainActor
final class RecordingReminderNotification {
    private let center = UNUserNotificationCenter.current()
    private let identifier = "recording-silence"
    // These nominally fire-and-forget APIs perform synchronous XPC internally.
    // Keep their ordering without making app startup or the stop button wait.
    private let queue = DispatchQueue(label: "com.aiworkdeck.recording-reminder")

    func requestPermission() async {
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert])
        }
    }

    func show() {
        let title = tr("rec.silence.title")
        let body = tr("rec.silence.message")
        queue.async { [identifier] in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            // No sound: an alert must not interrupt or be recorded by the microphone.
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: identifier, content: content,
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)))
        }
    }

    func clear() {
        queue.async { [identifier] in
            let center = UNUserNotificationCenter.current()
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
        }
    }
}
