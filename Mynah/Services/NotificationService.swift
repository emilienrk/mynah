// NotificationService.swift
// Mynah
//
// Manages macOS User Notifications for background warnings and alerts.

import Foundation
import UserNotifications
import os

private let logger = Logger(subsystem: "com.mynah", category: "NotificationService")

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()

    nonisolated static let recordingCategoryIdentifier = "RECORDING_DURATION_CATEGORY"
    nonisolated static let stopActionIdentifier = "STOP_RECORDING_ACTION"

    var onStopRecordingRequested: (() -> Void)?

    private var isConfigured = false

    /// Safe check to avoid calling UNUserNotificationCenter outside real application bundles.
    var isNotificationAvailable: Bool {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        guard !ProcessInfo.processInfo.environment.keys.contains("XCTestConfigurationFilePath") else { return false }
        return true
    }

    func setup() {
        guard isNotificationAvailable, !isConfigured else { return }
        isConfigured = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let stopAction = UNNotificationAction(
            identifier: Self.stopActionIdentifier,
            title: String(localized: "Arrêter l'enregistrement"),
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: Self.recordingCategoryIdentifier,
            actions: [stopAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        // Onboarding already asks for microphone and accessibility; don't stack a third
        // system prompt on top of it. Otherwise the first notification asks lazily.
        if AppSettings.shared.hasCompletedOnboarding {
            Task {
                await requestAuthorizationIfNeeded()
            }
        }
    }

    func requestAuthorizationIfNeeded() async {
        guard isNotificationAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }

    func sendCopiedNotification() async {
        guard isNotificationAvailable else { return }
        await requestAuthorizationIfNeeded()

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .notDetermined else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Texte copié dans le presse-papier")
        content.body  = String(localized: "Aucun champ de texte actif détecté. Collez avec ⌘V.")
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "com.mynah.copied-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
    }

    func sendRecordingDurationWarning(minutes: Int) async {
        guard isNotificationAvailable else { return }
        await requestAuthorizationIfNeeded()

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .notDetermined else { return }

        let content = UNMutableNotificationContent()
        content.title = String(localized: "Enregistrement en cours (\(minutes) min)")
        content.body  = String(localized: "Mynah enregistre depuis \(minutes) minutes. Pensez à arrêter la dictée si vous avez terminé.")
        content.sound = .default
        content.categoryIdentifier = Self.recordingCategoryIdentifier

        let request = UNNotificationRequest(
            identifier: "com.mynah.recording-duration-\(minutes)min",
            content: content,
            trigger: nil
        )
        try? await center.add(request)
        logger.info("Sent recording duration notification for \(minutes) min")
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionId = response.actionIdentifier
        if actionId == Self.stopActionIdentifier || actionId == UNNotificationDefaultActionIdentifier {
            Task { @MainActor in
                NotificationService.shared.onStopRecordingRequested?()
            }
        }
        completionHandler()
    }
}
