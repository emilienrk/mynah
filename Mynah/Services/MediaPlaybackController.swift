// MediaPlaybackController.swift
// Mynah
//
// Pauses whatever is playing while a dictation runs, then resumes it.
//
// Two rules decide everything here:
//
// 1. Mynah only acts when it can see a player actually feeding the output.
//    A player that is open but paused feeds nothing, so it is invisible, so it
//    is left alone — it must never be woken up by a dictation.
// 2. A call in progress means hands off entirely, music included. Interrupting
//    a conversation is worse than leaving a track running for a few seconds.
//
// The Play/Pause media key is a blind toggle routed to the system's now-playing
// app, which is not necessarily the process we saw playing. Seeing audio
// per process makes that toggle checkable: if the key woke a player instead of
// pausing one, a process that was silent is suddenly playing, and we undo it.

import Foundation
import AppKit
import ApplicationServices

@MainActor
protocol MediaKeySender {
    /// False when the system would drop the key. It does so without a word,
    /// so this has to be asked rather than read off the outcome.
    var canSend: Bool { get }
    func sendPlayPause()
}

/// What the floating indicator says about the playback.
enum MediaPauseStatus: Equatable {
    case idle
    /// Paused by us, and the verification found no player woken by the key.
    case paused
    /// Something is playing, but the key cannot be sent: no Accessibility.
    case blocked
}

@MainActor
protocol PlaybackStateTracker {
    func isKnownPaused(bundleID: String) -> Bool
}

// MARK: - Controller

@MainActor
@Observable
final class MediaPlaybackController {

    private let probe: AudioProcessProbe
    private let keySender: MediaKeySender
    private let stateTracker: PlaybackStateTracker
    private let isEnabled: @MainActor () -> Bool
    private let verifyDelay: Duration

    /// True while a player is paused *by us* and is owed a resume.
    @ObservationIgnored private(set) var didPause = false
    /// `.paused` only once verified, so a pause undone right away never
    /// flashes on screen.
    private(set) var pauseStatus = MediaPauseStatus.idle
    @ObservationIgnored private var verification: Task<Void, Never>?
    /// Bumped by every dictation start, so a resume still waiting on the
    /// verification can tell that a newer dictation now owns the pause.
    @ObservationIgnored private var dictation = 0

    /// `verifyDelay` covers the gap between the media key landing and the woken
    /// player showing up as playing. Measured at 74-84 ms on this hardware, for
    /// a process that had to be launched first; 400 ms is five times that.
    init(
        probe: AudioProcessProbe,
        keySender: MediaKeySender,
        stateTracker: PlaybackStateTracker = SystemPlaybackStateTracker(),
        isEnabled: @escaping @MainActor () -> Bool,
        verifyDelay: Duration = .milliseconds(400)
    ) {
        self.probe = probe
        self.keySender = keySender
        self.stateTracker = stateTracker
        self.isEnabled = isEnabled
        self.verifyDelay = verifyDelay
    }

    /// Returns as soon as the key is sent — the check runs on its own, so
    /// nothing is added to the delay before the microphone opens.
    func pauseForRecording() {
        dictation += 1

        // Already paused by us and never resumed. The key would start playback
        // rather than stop it, so this dictation takes the debt over, along
        // with a verification that may still be running.
        guard !didPause else { return }
        pauseStatus = .idle
        guard isEnabled() else { return }

        let playing = probe.outputtingProcesses()
        guard !playing.isEmpty,
              !playing.contains(where: { classify($0) == .communication })
        else { return }

        // Players that explicitly report as paused (e.g. Spotify or Music)
        // keep their CoreAudio output alive with silence. Skip them so we
        // don't toggle them into playing. Relays too: what they output is
        // another app's audio, which is no reason to send the key on its own.
        let activePlayers = playing.filter { process in
            guard classify(process) == .player else { return false }
            guard let bundleID = process.bundleID else { return true }
            return !stateTracker.isKnownPaused(bundleID: bundleID)
        }
        guard !activePlayers.isEmpty else { return }

        // A dropped key leaves the music playing, and the verification below,
        // seeing nothing new start, would confirm a pause that never happened.
        guard keySender.canSend else {
            pauseStatus = .blocked
            return
        }

        // Relays included: one already outputting must not pass for a player
        // the key just woke.
        let playingBefore = Set(playing.map(\.pid))
        keySender.sendPlayPause()
        didPause = true

        let delay = verifyDelay
        verification = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }

            // A process that was silent before the key is playing now: the
            // toggle reached a paused player instead of the one we saw. Undo it
            // and drop the debt, so the resume stays silent too.
            let playingNow = Set(self.probe.outputtingProcesses().map(\.pid))
            if !playingNow.subtracting(playingBefore).isEmpty {
                self.keySender.sendPlayPause()
                self.didPause = false
            } else {
                self.pauseStatus = .paused
            }
        }
    }

    /// Safe to call from every pipeline exit path — errors included. The
    /// `didPause` guard makes repeated calls no-ops.
    ///
    /// Deliberately not conditioned on the paused player having gone quiet:
    /// players keep their audio unit alive for seconds after a pause, so
    /// demanding proof of silence would strand the music paused.
    ///
    /// Synchronous on purpose: which dictation the resume belongs to is decided
    /// at the call, not when a task gets to run — by then the next dictation
    /// may have started, and the music would come back in the middle of it.
    @discardableResult
    func resumeAfterRecording() -> Task<Void, Never> {
        let owner = dictation
        let pending = verification
        return Task { [weak self] in
            await pending?.value
            // A dictation started meanwhile carries the pause on; its own
            // resume settles it.
            guard let self, self.dictation == owner else { return }
            self.verification = nil
            self.pauseStatus = .idle

            guard self.didPause else { return }
            self.didPause = false
            self.keySender.sendPlayPause()
        }
    }
}

// MARK: - Real implementation

/// Posts the system Play/Pause media key. Relies on the Accessibility
/// permission the paste already needs, so no new prompt is asked for —
/// posting a media key still requires it even though this goes through the
/// HID event tap rather than the session tap ClipboardService uses.
struct SystemMediaKeySender: MediaKeySender {

    /// NX_KEYTYPE_PLAY from IOKit's hidsystem/ev_keymap.h.
    private static let playPauseKey: Int32 = 16

    var canSend: Bool { AXIsProcessTrusted() }

    func sendPlayPause() {
        post(keyDown: true)
        post(keyDown: false)
    }

    private func post(keyDown: Bool) {
        let state: Int32 = keyDown ? 0xA : 0xB
        let data1 = Int((Self.playPauseKey << 16) | (state << 8))
        let flags = NSEvent.ModifierFlags(rawValue: keyDown ? 0xA00 : 0xB00)

        guard let event = NSEvent.otherEvent(
            with: .systemDefined,
            location: .zero,
            modifierFlags: flags,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            subtype: 8,
            data1: data1,
            data2: -1
        ) else { return }

        event.cgEvent?.post(tap: .cghidEventTap)
    }
}

/// Observes distributed notifications broadcast by Spotify and Apple Music
/// to track whether they are explicitly paused.
@MainActor
final class SystemPlaybackStateTracker: NSObject, PlaybackStateTracker {

    private var pausedBundleIDs: Set<String> = []

    override init() {
        super.init()
        let center = DistributedNotificationCenter.default()

        center.addObserver(
            self,
            selector: #selector(handleSpotifyNotification(_:)),
            name: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )

        center.addObserver(
            self,
            selector: #selector(handleMusicNotification(_:)),
            name: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
    }

    @objc nonisolated private func handleSpotifyNotification(_ notification: Notification) {
        let state = notification.userInfo?["Player State"] as? String
        Task { @MainActor in
            self.updateState(state, bundleID: "com.spotify.client")
        }
    }

    @objc nonisolated private func handleMusicNotification(_ notification: Notification) {
        let state = notification.userInfo?["Player State"] as? String
        Task { @MainActor in
            self.updateState(state, bundleID: "com.apple.Music")
        }
    }

    private func updateState(_ state: String?, bundleID: String) {
        guard let state else { return }
        switch state.lowercased() {
        case "paused", "stopped":
            pausedBundleIDs.insert(bundleID)
        case "playing":
            pausedBundleIDs.remove(bundleID)
        default:
            break
        }
    }

    func isKnownPaused(bundleID: String) -> Bool {
        pausedBundleIDs.contains(bundleID)
    }
}

