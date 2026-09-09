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

    private func makeCoordinator() -> RecordingCoordinator {
        let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WhispeurWatchdogTests-\(UUID().uuidString)", isDirectory: true)
        return RecordingCoordinator(
            hotkeyManager: HotkeyManager(),
            audioCapture: AudioCaptureService(),
            whisperService: WhisperService(),
            clipboardService: ClipboardService(),
            historyService: HistoryService(directory: tempDir),
            mediaPlayback: MediaPlaybackController(
                probe: CoreAudioProcessProbe(),
                keySender: SystemMediaKeySender(),
                isEnabled: { false }
            )
        )
    }

    @Test("Watchdog triggers warning notification when recording reaches milestone")
    func watchdogTriggersMilestone() async {
        let coordinator = makeCoordinator()
        coordinator.setPipelineStateForTesting(.recording)
        coordinator.recordingWatchdogMilestones = [0.03] // 30 milliseconds

        var notified: [Int] = []
        coordinator.notifyRecordingDuration = { minutes in
            notified.append(minutes)
        }

        coordinator.startRecordingWatchdog()
        try? await Task.sleep(for: .milliseconds(120))
        coordinator.stopRecordingWatchdog()

        #expect(!notified.isEmpty)
    }

    @Test("Normal short dictation stops watchdog without any notification")
    func watchdogSilentOnNormalDictation() async {
        let coordinator = makeCoordinator()
        coordinator.setPipelineStateForTesting(.recording)
        coordinator.recordingWatchdogMilestones = [1.0] // 1 second milestone

        var notified: [Int] = []
        coordinator.notifyRecordingDuration = { minutes in
            notified.append(minutes)
        }

        // Start watchdog for normal dictation
        coordinator.startRecordingWatchdog()
        // Dictation finishes quickly after 20ms
        try? await Task.sleep(for: .milliseconds(20))
        coordinator.stopRecordingWatchdog()
        coordinator.setPipelineStateForTesting(.idle)

        // Wait a short delay to ensure no delayed triggers occur
        try? await Task.sleep(for: .milliseconds(50))

        #expect(notified.isEmpty)
    }

    @Test("Clicking notification stop action stops recording")
    func stopRecordingNotificationAction() {
        let coordinator = makeCoordinator()
        coordinator.setPipelineStateForTesting(.recording)

        // Trigger notification stop action
        NotificationService.shared.onStopRecordingRequested?()

        #expect(coordinator.pipelineState != .recording)
    }
}
