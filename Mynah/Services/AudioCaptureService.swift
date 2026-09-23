// AudioCaptureService.swift
// Mynah
//
// Audio capture engine using AVAudioEngine.
// Converts input to 16kHz Mono Float32 in memory.
//
// THREAD MODEL:
// - startRecording / stopRecording run on @MainActor.
// - installTap callback fires on AVFoundation’s realtime thread.
// - We accumulate samples in a thread-safe box (lock-protected),
//   then drain into sampleBuffer in stopRecording() on the main actor.
//   MainActor.assumeIsolated is NEVER called from the realtime thread.
//
// ROUTE CHANGES:
// The engine runs on an input+output aggregate device. Opening the mic of a
// Bluetooth headset flips it from A2DP to HFP, which changes that device's
// format mid-recording: the engine stops itself and posts a configuration
// change. The capture is rebuilt on the new format, keeping the samples
// already taken, otherwise the mic goes dark while the UI keeps counting.

@preconcurrency import AVFoundation
import Foundation
import os
import Synchronization

private let logger = Logger(subsystem: "com.mynah", category: "AudioCapture")

enum AudioCaptureError: Error, LocalizedError {
    case permissionDenied
    case engineSetupFailed(String)
    case converterSetupFailed
    case noInputAvailable
    case inputLost

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return String(localized: "Accès au micro refusé.")
        case .engineSetupFailed(let detail): return String(localized: "Échec du démarrage audio : \(detail)")
        case .converterSetupFailed: return String(localized: "Échec de la conversion audio.")
        case .noInputAvailable: return String(localized: "Aucune entrée audio disponible.")
        case .inputLost: return String(localized: "Entrée audio perdue pendant l'enregistrement.")
        }
    }
}

enum RecordingState: Equatable {
    case idle
    case recording
    case stopping
}

/// Target whisper.cpp format: 16kHz, Mono, Float32.
private let kWhisperAudioFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
)!

/// Thread-safe accumulator for realtime audio samples.
/// Appended on AVFoundation realtime thread, drained on MainActor.
final class SamplesAccumulator: Sendable {
    private let mutex = Mutex<[Float]>([])

    func append(_ samples: [Float]) {
        mutex.withLock { $0.append(contentsOf: samples) }
    }

    func drainAll() -> [Float] {
        mutex.withLock {
            let result = $0
            $0.removeAll(keepingCapacity: true)
            return result
        }
    }

    /// Read-only sample count — never drains, so it is safe to poll while recording.
    var count: Int {
        mutex.withLock { $0.count }
    }
}

/// Spots a capture that died without a configuration change being posted.
/// Silence still delivers buffers, so a count that stops growing means the tap
/// is no longer fed — not that the user went quiet.
struct CaptureStallDetector {
    /// Consecutive checks without new samples before calling it a stall. Leaves
    /// a Bluetooth headset the second or two it takes to deliver its first buffer.
    var toleratedIdleChecks = 2

    private var lastCount: Int?
    private var idleChecks = 0

    mutating func isStalled(sampleCount: Int, engineRunning: Bool) -> Bool {
        guard engineRunning else { return true }
        defer { lastCount = sampleCount }
        guard sampleCount == lastCount else {
            idleChecks = 0
            return false
        }
        idleChecks += 1
        return idleChecks >= toleratedIdleChecks
    }

    mutating func reset() {
        lastCount = nil
        idleChecks = 0
    }
}

/// Real-time audio capture service.
@MainActor
@Observable
final class AudioCaptureService {

    private(set) var state: RecordingState = .idle
    private(set) var lastError: AudioCaptureError?

    static var whisperFormat: AVAudioFormat { kWhisperAudioFormat }

    private var audioEngine = AVAudioEngine()
    private var converter: AVAudioConverter?
    /// Thread-safe accumulator — written from realtime tap, drained in stopRecording().
    private let accumulator = SamplesAccumulator()

    private let tapBufferSize: AVAudioFrameCount = 4096

    /// Called when the input is gone for good mid-recording; the samples taken
    /// until then are still returned by stopRecording().
    var onInputLost: (@MainActor () -> Void)?

    private var configurationObserver: (any NSObjectProtocol)?
    private var healthCheckTask: Task<Void, Never>?
    private var stallDetector = CaptureStallDetector()
    private var restartCount = 0
    /// A headset switching profiles takes one restart; more than a few means
    /// the route keeps flapping and retrying would only hide it.
    private let maxRestarts = 3

    func startRecording() throws {
        guard state == .idle else {
            logger.debug("startRecording() skipped — already in state: \(String(describing: self.state))")
            return
        }

        lastError = nil
        restartCount = 0
        stallDetector.reset()
        // Drain any leftover samples from a previous session.
        _ = accumulator.drainAll()

        try launchEngine()

        state = .recording
        startHealthCheck()
        logger.info("Recording started")
    }

    func stopRecording() -> [Float] {
        guard state == .recording else {
            logger.debug("stopRecording() skipped — not recording (state=\(String(describing: self.state)))")
            return []
        }

        state = .stopping
        healthCheckTask?.cancel()
        healthCheckTask = nil
        teardownEngine()

        // Drain accumulated samples on the MainActor (safe).
        let captured = accumulator.drainAll()
        state = .idle
        logger.info("Recording stopped — \(captured.count) samples (\(String(format: "%.2f", Double(captured.count) / 16_000.0))s)")
        return captured
    }

    private func launchEngine() throws {
        try setupEngine()

        do {
            try audioEngine.start()
        } catch {
            audioEngine.inputNode.removeTap(onBus: 0)
            audioEngine.reset()
            logger.error("Engine start failed: \(error)")
            throw AudioCaptureError.engineSetupFailed(error.localizedDescription)
        }

        observeConfigurationChanges()
    }

    private func teardownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        audioEngine.reset()
    }

    private func observeConfigurationChanges() {
        let engineID = ObjectIdentifier(audioEngine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                // A notification queued before a restart belongs to the engine
                // that restart already replaced.
                guard let self, ObjectIdentifier(self.audioEngine) == engineID else { return }
                self.restartCapture(reason: "configuration change")
            }
        }
    }

    /// Catches an engine that stopped delivering buffers without posting a
    /// configuration change.
    private func startHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.state == .recording else { return }
                if self.stallDetector.isStalled(
                    sampleCount: self.accumulator.count,
                    engineRunning: self.audioEngine.isRunning
                ) {
                    self.restartCapture(reason: "input stalled")
                }
            }
        }
    }

    private func restartCapture(reason: String) {
        guard state == .recording else { return }

        guard restartCount < maxRestarts else {
            logger.error("Input lost (\(reason)) — restart budget exhausted")
            loseInput()
            return
        }
        restartCount += 1
        logger.notice("Restarting capture (\(reason)), attempt \(self.restartCount)")

        teardownEngine()
        stallDetector.reset()
        do {
            try launchEngine()
        } catch {
            logger.error("Capture restart failed: \(error)")
            loseInput()
        }
    }

    private func loseInput() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
        teardownEngine()
        lastError = .inputLost
        // Stays .recording so stopRecording() still hands back what was captured.
        onInputLost?()
    }

    private func setupEngine() throws {
        audioEngine = AVAudioEngine()
        let inputNode = audioEngine.inputNode
        let nativeFormat = inputNode.outputFormat(forBus: 0)

        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            logger.error("No audio input available (sampleRate=\(nativeFormat.sampleRate) channels=\(nativeFormat.channelCount))")
            throw AudioCaptureError.noInputAvailable
        }

        logger.debug("Native format: \(nativeFormat.sampleRate)Hz \(nativeFormat.channelCount)ch")

        guard let conv = AVAudioConverter(from: nativeFormat, to: Self.whisperFormat) else {
            logger.error("AVAudioConverter init failed")
            throw AudioCaptureError.converterSetupFailed
        }
        converter = conv

        let ratio = nativeFormat.sampleRate / Self.whisperFormat.sampleRate
        let outputFrameCapacity = AVAudioFrameCount(Double(tapBufferSize) / ratio) + 1

        let tapBlock = Self.createTapBlock(
            converter: conv,
            outputFrameCapacity: outputFrameCapacity,
            accumulator: accumulator
        )

        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: nativeFormat, block: tapBlock)
    }

    /// Creates the tap closure in a strictly nonisolated context.
    /// This prevents Swift 6 from implicitly inheriting @MainActor isolation for the closure,
    /// which would cause a crash when AVFoundation calls it from `RealtimeMessenger.mServiceQueue`.
    nonisolated private static func createTapBlock(
        converter: AVAudioConverter,
        outputFrameCapacity: AVAudioFrameCount,
        accumulator: SamplesAccumulator
    ) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            AudioCaptureService.convertAndAccumulate(
                buffer,
                converter: converter,
                outputFrameCapacity: outputFrameCapacity,
                into: accumulator
            )
        }
    }

    /// Converts a native-format buffer to 16kHz Float32 and appends to the accumulator.
    /// Static + nonisolated: never touches MainActor state.
    nonisolated private static func convertAndAccumulate(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputFrameCapacity: AVAudioFrameCount,
        into accumulator: SamplesAccumulator
    ) {
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: kWhisperAudioFormat,
            frameCapacity: outputFrameCapacity
        ) else { return }

        var conversionError: NSError?
        let provided = InputProvidedBox()

        let status = converter.convert(to: outputBuffer, error: &conversionError) { [inputBuffer] _, outStatus in
            if provided.value {
                outStatus.pointee = .noDataNow
                return nil
            }
            provided.value = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error, conversionError == nil,
              outputBuffer.frameLength > 0,
              let channelData = outputBuffer.floatChannelData?[0] else { return }

        let frameCount = Int(outputBuffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        accumulator.append(samples)
    }
}

extension AudioCaptureService {
    var recordedDuration: Double {
        Double(accumulator.count) / kWhisperAudioFormat.sampleRate
    }
}

/// Simple reference-type boolean box used to share mutable state
/// with a @Sendable converter callback without triggering Swift 6 warnings.
private final class InputProvidedBox: @unchecked Sendable {
    var value: Bool = false
}
