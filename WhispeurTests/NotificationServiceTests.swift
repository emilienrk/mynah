// NotificationServiceTests.swift
// WhispeurTests

import Testing
import Foundation

@MainActor
struct NotificationServiceTests {

    @Test("NotificationService reports unavailable in headless test environment")
    func unavailableInTests() {
        let service = NotificationService.shared
        #expect(service.isNotificationAvailable == false)
    }

    @Test("Calling notification methods does not crash or trap in tests")
    func safeCallsInTests() async {
        let service = NotificationService.shared
        service.setup()
        await service.sendCopiedNotification()
        await service.sendRecordingDurationWarning(minutes: 3)
        await service.sendRecordingDurationWarning(minutes: 10)
    }

    @Test("Stop recording callback triggers correctly")
    func stopRecordingCallback() {
        var stopped = false
        NotificationService.shared.onStopRecordingRequested = {
            stopped = true
        }

        NotificationService.shared.onStopRecordingRequested?()
        #expect(stopped == true)
    }
}
