// RecordingCoordinator.swift
// Whispeur
//
// Orchestrates the full end-to-end pipeline:
// HotKey pressed → AudioCapture starts + Whisper model loads (parallel)
//              → HotKey released → Audio stops
//              → Whisper transcribes
//              → ClipboardService pastes text
//              → Whisper model unloaded immediately (0s, as per RAM policy)

import Foundation
import AppKit
import os

// MARK: - Pipeline State

enum PipelineState: Equatable {
    case idle
    case loadingModel
    case recording
    case transcribing
    case pasting
    case error(String)

    var isActive: Bool {
        switch self {
        case .idle, .error: return false
        default: return true
        }
    }
}

// MARK: - RecordingCoordinator

@MainActor
@Observable
final class RecordingCoordinator {

    // MARK: Observed state

    private(set) var pipelineState: PipelineState = .idle
    private(set) var lastTranscription: String = ""
    private(set) var lastError: String?

    // MARK: Services (injected)

    let hotkeyManager: HotkeyManager
    let audioCapture: AudioCaptureService
    let whisperService: WhisperService
    let clipboardService: ClipboardService
    let historyService: HistoryService
    let mediaPlayback: MediaPlaybackController

    // MARK: Configuration

    /// URL to the ggml model file used for transcription.
    var modelURL: URL? {
        didSet { /* Reset loaded state so the model reloads on next use. */ }
    }
    var language: WhisperLanguage = .auto

    // MARK: - Long recording duration watchdog

    /// Milestones in seconds to alert the user of ongoing recording (default: 3 min, 10 min, 15 min).
    var recordingWatchdogMilestones: [TimeInterval] = [180, 600, 900]

    /// Injected notification handler for duration warnings.
    var notifyRecordingDuration: (Int) async -> Void = { minutes in
        await NotificationService.shared.sendRecordingDurationWarning(minutes: minutes)
    }

    // MARK: Private

    private let logger = Logger(subsystem: "com.whispeur", category: "RecordingCoordinator")
    /// Tracks whether a transcription pipeline is already running.
    private var pipelineTask: Task<Void, Never>?
    /// Tracks a pending model unload task.
    private var unloadTask: Task<Void, Never>?
    /// Watchdog task for long recording notifications.
    private var recordingWatchdogTask: Task<Void, Never>?

    // MARK: Init

    init(
        hotkeyManager: HotkeyManager,
        audioCapture: AudioCaptureService,
        whisperService: WhisperService,
        clipboardService: ClipboardService,
        historyService: HistoryService,
        mediaPlayback: MediaPlaybackController
    ) {
        self.hotkeyManager  = hotkeyManager
        self.audioCapture   = audioCapture
        self.whisperService = whisperService
        self.clipboardService = clipboardService
        self.historyService = historyService
        self.mediaPlayback  = mediaPlayback

        configureHotkeyCallbacks()
        NotificationService.shared.onStopRecordingRequested = { [weak self] in
            guard let self else { return }
            if self.pipelineState == .recording || self.pipelineState == .loadingModel {
                self.finishRecording()
            }
        }
    }

    // MARK: - Hotkey wiring

    private func configureHotkeyCallbacks() {
        hotkeyManager.onKeyDown = { [weak self] in
            guard let self else { return }
            self.onHotkeyDown()
        }
        hotkeyManager.onKeyUp = { [weak self] in
            guard let self else { return }
            self.onHotkeyUp()
        }
    }

    // MARK: - Push-to-Talk lifecycle

    func onHotkeyDown() {
        guard pipelineState == .idle else { return }
        pipelineTask = Task { await startPipeline() }
    }

    func onHotkeyUp() {
        // In Push-to-Talk mode: stop recording when the key is released.
        // In Toggle mode: onHotkeyUp is never called by HotkeyManager.
        finishRecording()
    }

    // MARK: - Toggle lifecycle

    /// Called by HotkeyManager in toggle mode on the second press.
    func stopToggle() {
        finishRecording()
    }

    // MARK: - Pipeline

    /// Phase 1: start audio capture + load Whisper model in parallel.
    private func startPipeline() async {
        guard let modelURL else {
            setError("Aucun modèle Whisper sélectionné.")
            return
        }

        // Cancel any pending unload so the model stays loaded if we're quick enough.
        unloadTask?.cancel()
        unloadTask = nil

        // Reads audio per process and skips our own, so opening the mic right
        // after cannot pollute the reading. Returns before the key is verified.
        mediaPlayback.pauseForRecording()

        // Played before the tap opens, so the mic does not capture the chime
        // and hand Whisper a sound to hallucinate a word out of.
        FeedbackSound.started.play()

        // --- Start audio immediately ---
        do {
            try audioCapture.startRecording()
        } catch {
            setError("Micro : \(error.localizedDescription)")
            return
        }

        // --- Load model concurrently while the user speaks ---
        pipelineState = .loadingModel
        do {
            try await whisperService.loadModel(at: modelURL, language: language, useGPU: AppSettings.shared.useGPU)
        } catch {
            _ = audioCapture.stopRecording()
            setError("Chargement modèle : \(error.localizedDescription)")
            return
        }

        // Model is ready; transition to active recording state.
        pipelineState = .recording
        startRecordingWatchdog()
        logger.info("Pipeline started — recording…")
    }

    /// Phase 2: stop audio, transcribe, paste, unload model.
    func finishRecording() {
        stopRecordingWatchdog()
        guard pipelineState == .recording || pipelineState == .loadingModel else { return }

        let samples = audioCapture.stopRecording()

        // Resume right away rather than after transcription — a large model can
        // take seconds, and the silence is noticeable.
        Task { await mediaPlayback.resumeAfterRecording() }

        guard !samples.isEmpty else {
            pipelineState = .idle
            unloadModel()
            return
        }

        // Run phases 2-4 in a Task to keep the UI responsive.
        Task { await runTranscriptionAndPaste(samples: samples) }
    }

    private func runTranscriptionAndPaste(samples: [Float]) async {
        // Phase 2: Transcription
        pipelineState = .transcribing
        let engineConfig = AppSettings.shared.engineConfig
        let text: String
        do {
            text = try await whisperService.transcribe(samples: samples, config: engineConfig)
        } catch {
            setError("Transcription : \(error.localizedDescription)")
            unloadModel()
            return
        }

        logger.info("Transcription OK: \(text.prefix(80))")

        // Unload the model after the configured delay.
        unloadModel()

        guard !text.isEmpty else {
            pipelineState = .idle
            return
        }

        // Phase 3: Paste & Save History
        pipelineState = .pasting
        lastTranscription = text

        FeedbackSound.finished.play()

        if AppSettings.shared.hasCompletedOnboarding {
            let result = await clipboardService.copyAndPaste(text)
            logger.info("Paste result: \(String(describing: result))")
            
            // Save to history
            historyService.add(text)
        } else {
            logger.info("Skipping paste and history during onboarding test")
        }

        pipelineState = .idle
    }

    // MARK: - Helpers

    private func unloadModel() {
        unloadTask?.cancel()
        let delay = AppSettings.shared.modelUnloadDelay
        if delay > 0 {
            unloadTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await whisperService.unloadModel()
            }
        } else {
            unloadTask = Task { await whisperService.unloadModel() }
        }
    }

    private func setError(_ message: String) {
        stopRecordingWatchdog()
        lastError = message
        pipelineState = .error(message)
        logger.error("Pipeline error: \(message)")
        Task { await mediaPlayback.resumeAfterRecording() }
        // Auto-reset to idle after a short delay so the UI recovers.
        Task {
            try? await Task.sleep(for: .seconds(3))
            if case .error = self.pipelineState {
                self.pipelineState = .idle
            }
        }
    }

    func startRecordingWatchdog() {
        stopRecordingWatchdog()
        let startTime = Date()
        let milestones = recordingWatchdogMilestones
        recordingWatchdogTask = Task { [weak self] in
            var nextIndex = 0

            while !Task.isCancelled {
                let targetSeconds: TimeInterval
                if nextIndex < milestones.count {
                    targetSeconds = milestones[nextIndex]
                } else {
                    let last = milestones.last ?? 900
                    let extra = Double(nextIndex - milestones.count + 1)
                    targetSeconds = last + (extra * 300)
                }

                let elapsed = Date().timeIntervalSince(startTime)
                let remaining = targetSeconds - elapsed
                if remaining > 0 {
                    do {
                        try await Task.sleep(for: .seconds(remaining))
                    } catch {
                        return
                    }
                }

                guard !Task.isCancelled else { return }
                guard let self, self.pipelineState == .recording else { return }

                let elapsedMinutes = max(1, Int(round(Date().timeIntervalSince(startTime) / 60)))
                await self.notifyRecordingDuration(elapsedMinutes)
                nextIndex += 1
            }
        }
    }

    func stopRecordingWatchdog() {
        recordingWatchdogTask?.cancel()
        recordingWatchdogTask = nil
    }

    func setPipelineStateForTesting(_ state: PipelineState) {
        self.pipelineState = state
    }
}

// MARK: - Audio feedback

/// Short system sounds telling the user the mic opened and the text landed —
/// dictation is eyes-free, the menu bar icon alone is not enough.
private enum FeedbackSound {
    case started
    case finished

    @MainActor
    func play() {
        let settings = AppSettings.shared
        guard settings.confirmationSoundEnabled else { return }
        SystemSoundLibrary.play(named: name(from: settings))
    }

    @MainActor
    private func name(from settings: AppSettings) -> String {
        switch self {
        case .started:  settings.startSoundName
        case .finished: settings.finishSoundName
        }
    }
}
