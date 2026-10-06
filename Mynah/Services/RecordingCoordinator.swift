// RecordingCoordinator.swift
// Mynah
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

// MARK: - Dictation Outcome

/// How a dictation ended. Held past the return to `.idle`, which can follow
/// `.pasting` too closely for an observer to ever see the latter — when there
/// is nothing to paste into, nothing in between suspends.
struct DictationOutcome: Equatable {
    enum Kind: Equatable {
        /// The paste result is nil when the text was not handed to the
        /// clipboard at all — the onboarding test run.
        case transcribed(String, PasteResult?)
        case silent
        /// Dropped by the user, from the pill or with Escape.
        case cancelled
    }

    /// Tells two identical outcomes in a row apart.
    let id: Int
    let kind: Kind
}

// MARK: - RecordingCoordinator

@MainActor
@Observable
final class RecordingCoordinator {

    // MARK: Observed state

    private(set) var pipelineState: PipelineState = .idle {
        didSet {
            switch pipelineState {
            case .loadingModel, .recording, .transcribing: hotkeyManager.setCancelArmed(true)
            case .idle, .pasting, .error: hotkeyManager.setCancelArmed(false)
            }
        }
    }
    private(set) var lastTranscription: String = ""
    /// True when the last run transcribed successfully but produced nothing. Distinct
    /// from "never ran": callers must be able to say so instead of looking idle.
    private(set) var lastRunWasSilent: Bool = false
    private(set) var lastError: String?
    /// When the mic opened. Set before the model finishes loading, so a timer
    /// shown from here does not restart when the state moves on to `.recording`.
    private(set) var recordingStartedAt: Date?
    /// Set when a dictation ends with a result or is cancelled — not when it fails.
    private(set) var lastOutcome: DictationOutcome?

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

    private let logger = Logger(category: "RecordingCoordinator")
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
        // Ends the dictation with what was captured, rather than letting the
        // counter run over a mic that is no longer open.
        audioCapture.onInputLost = { [weak self] in
            self?.finishRecording()
        }
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
        hotkeyManager.onCancel = { [weak self] in
            self?.cancelRecording()
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
            setError(String(localized: "Aucun modèle Whisper sélectionné."))
            return
        }

        // Cancel any pending unload so the model stays loaded if we're quick enough.
        unloadTask?.cancel()
        unloadTask = nil

        AccessibilityWaker.wakeFrontmostApp()

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
            setError(String(localized: "Micro : \(error.localizedDescription)"))
            return
        }
        recordingStartedAt = Date()
        lastRunWasSilent = false

        // --- Load model concurrently while the user speaks ---
        pipelineState = .loadingModel
        do {
            try await whisperService.loadModel(at: modelURL, language: language, useGPU: AppSettings.shared.useGPU)
        } catch {
            guard !Task.isCancelled else { return }
            _ = audioCapture.stopRecording()
            setError(String(localized: "Chargement modèle : \(error.localizedDescription)"))
            return
        }

        // The recording may have ended while the model loaded — key released
        // early, or the input lost. Going back to .recording would restart the
        // counter over a closed mic. A cancelled run must also not take over the
        // `.loadingModel` of a dictation started right after it.
        guard !Task.isCancelled, pipelineState == .loadingModel else { return }

        // Model is ready; transition to active recording state.
        pipelineState = .recording
        startRecordingWatchdog()
        logger.info("Pipeline started — recording…")
    }

    /// Phase 2: stop audio, transcribe, paste, unload model.
    func finishRecording() {
        guard pipelineState == .recording || pipelineState == .loadingModel else { return }
        stopRecordingWatchdog()
        // Stops from the HUD, a notification or a lost input bypass the hotkey,
        // which would otherwise need a second press to realise it is off.
        hotkeyManager.resetToggle()
        recordingStartedAt = nil

        let samples = audioCapture.stopRecording()

        // Resume right away rather than after transcription — a large model can
        // take seconds, and the silence is noticeable.
        mediaPlayback.resumeAfterRecording()

        guard !samples.isEmpty else {
            unloadModel()
            if let captureError = audioCapture.lastError {
                setError(String(localized: "Micro : \(captureError.localizedDescription)"))
            } else {
                pipelineState = .idle
            }
            return
        }

        // Set before the Task runs, so a model load finishing in between sees
        // the recording is over.
        pipelineState = .transcribing
        // Run phases 2-4 in a Task to keep the UI responsive.
        pipelineTask = Task { await runTranscriptionAndPaste(samples: samples) }
    }

    /// Drops the dictation — recording or transcription — without pasting or saving history.
    func cancelRecording() {
        switch pipelineState {
        case .loadingModel, .recording:
            stopRecordingWatchdog()
            hotkeyManager.resetToggle()
            recordingStartedAt = nil
            _ = audioCapture.stopRecording()
            mediaPlayback.resumeAfterRecording()
        case .transcribing:
            break
        case .idle, .pasting, .error:
            return
        }
        logger.info("Dictation cancelled")
        // Cancelling aborts whisper.cpp mid-run; the task then returns without
        // touching the state, which may already belong to the next dictation.
        pipelineTask?.cancel()
        pipelineTask = nil
        unloadModel()
        endRun(with: .cancelled)
    }

    private func runTranscriptionAndPaste(samples: [Float]) async {
        // Phase 2: Transcription
        let engineConfig = AppSettings.shared.engineConfig
        let text: String
        do {
            text = try await whisperService.transcribe(samples: samples, config: engineConfig)
        } catch {
            guard !Task.isCancelled else { return }
            setError(String(localized: "Transcription : \(error.localizedDescription)"))
            unloadModel()
            return
        }

        guard !Task.isCancelled else { return }

        logger.info("Transcription OK: \(text.prefix(80), privacy: .private)")

        // Unload the model after the configured delay.
        unloadModel()

        guard !text.isEmpty else {
            lastRunWasSilent = true
            endRun(with: .silent)
            return
        }

        // Phase 3: Paste & Save History
        pipelineState = .pasting
        lastTranscription = text

        FeedbackSound.finished.play()

        var pasteResult: PasteResult?
        if AppSettings.shared.hasCompletedOnboarding {
            let result = await clipboardService.copyAndPaste(text)
            logger.info("Paste result: \(String(describing: result), privacy: .public)")
            pasteResult = result

            // Save to history
            historyService.add(text)
        } else {
            logger.info("Skipping paste and history during onboarding test")
        }

        endRun(with: .transcribed(text, pasteResult))
    }

    /// Records the outcome before going idle, so an observer woken by `.idle` finds it.
    private func endRun(with kind: DictationOutcome.Kind) {
        lastOutcome = DictationOutcome(id: (lastOutcome?.id ?? 0) + 1, kind: kind)
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
            unloadTask = Task {
                guard !Task.isCancelled else { return }
                await whisperService.unloadModel()
            }
        }
    }

    private func setError(_ message: String) {
        stopRecordingWatchdog()
        recordingStartedAt = nil
        lastError = message
        pipelineState = .error(message)
        logger.error("Pipeline error: \(message, privacy: .public)")
        mediaPlayback.resumeAfterRecording()
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

#if DEBUG
    /// Test-only hook: drives the pipeline without real audio hardware. Debug builds only.
    func setPipelineStateForTesting(_ state: PipelineState) {
        self.pipelineState = state
    }
#endif
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
