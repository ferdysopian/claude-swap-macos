//
//  NotificationService.swift
//  ClaudeSwap
//
//  Thin wrapper around UserNotifications for the handful of alerts Claude
//  Swap posts: automatic switches, exhaustion warnings, quarantines.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()
    private var authorized = false

    private init() {}

    func requestAuthorizationIfNeeded() async {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            authorized = true
        case .notDetermined:
            authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            authorized = false
        }
    }

    func notifySwitch(from: String?, to displayName: String, trigger: String) {
        post(
            title: "Switched account",
            body: "Now using \(displayName)" + (trigger == "manual" ? "" : " (\(trigger))"),
            identifier: "switch-\(UUID().uuidString)"
        )
    }

    func notifyExhausted(accountName: String) {
        post(
            title: "Account exhausted",
            body: "\(accountName) has hit its usage limit.",
            identifier: "exhausted-\(accountName)"
        )
    }

    func notifyQuarantined(accountName: String, reason: String) {
        post(
            title: "Account needs attention",
            body: "\(accountName) was taken out of rotation: \(reason).",
            identifier: "quarantine-\(accountName)"
        )
    }

    private func post(title: String, body: String, identifier: String) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request)
    }
}
