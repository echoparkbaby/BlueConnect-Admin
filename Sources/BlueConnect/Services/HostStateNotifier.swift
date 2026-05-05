import Foundation
import UserNotifications

/// Watches for host active/inactive transitions across refreshes and fires
/// local user notifications when toggled. Per-host transitions are recorded
/// in the activity log even when notifications are disabled.
@MainActor
@Observable
final class HostStateNotifier {
    @ObservationIgnored private var lastActive: [Int: Bool] = [:]
    @ObservationIgnored private var hasRequestedAuth: Bool = false

    func snapshotInitial(_ hosts: [BlueSkyHost]) {
        // Don't notify on the first observed state — just record it.
        lastActive = Dictionary(uniqueKeysWithValues: hosts.map { ($0.blueskyid, $0.active) })
    }

    func diff(_ hosts: [BlueSkyHost], settings: SettingsStore, activity: ActivityLog) {
        guard !lastActive.isEmpty else {
            snapshotInitial(hosts)
            return
        }
        var transitions: [(BlueSkyHost, Bool)] = [] // (host, becameActive)
        for h in hosts {
            if let prev = lastActive[h.blueskyid], prev != h.active {
                transitions.append((h, h.active))
            }
            lastActive[h.blueskyid] = h.active
        }
        guard !transitions.isEmpty else { return }

        for (h, becameActive) in transitions {
            let title = becameActive ? "Host online" : "Host offline"
            let body = "\(h.displayName) (#\(h.blueskyid))"
            activity.record(.connect, title: title, detail: body)
            if settings.notifyOnStateChange {
                fireNotification(title: title, body: body, identifier: "host-\(h.blueskyid)-\(becameActive)")
            }
        }
    }

    func requestAuthorizationIfNeeded() {
        guard !hasRequestedAuth else { return }
        hasRequestedAuth = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, err in
            if let err = err { NSLog("Notification auth error: \(err.localizedDescription)") }
            NSLog("Notification auth granted: \(granted)")
        }
    }

    private func fireNotification(title: String, body: String, identifier: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier + "-" + UUID().uuidString,
                                            content: content,
                                            trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
