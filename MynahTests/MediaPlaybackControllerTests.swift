// MediaPlaybackControllerTests.swift
// MynahTests

import Testing

private func player(_ pid: pid_t, _ bundleID: String = "com.spotify.client") -> AudioProcess {
    AudioProcess(pid: pid, bundleID: bundleID, capture: .none)
}

/// A call detected the way FaceTime is: playing and capturing at once.
private func call(_ pid: pid_t, _ bundleID: String = "com.apple.avconferenced") -> AudioProcess {
    AudioProcess(pid: pid, bundleID: bundleID, capture: .microphone)
}

/// A per-app volume mixer: it taps every app's audio and plays it back, with
/// no microphone open.
private func relay(_ pid: pid_t, _ bundleID: String = "com.vorssaint.utils") -> AudioProcess {
    AudioProcess(pid: pid, bundleID: bundleID, capture: .appAudio)
}

@MainActor
private final class FakeProcessProbe: AudioProcessProbe {
    private var readings: [[AudioProcess]]
    private var lastReading: [AudioProcess] = []
    private(set) var readCount = 0

    init(_ readings: [[AudioProcess]]) { self.readings = readings }

    func outputtingProcesses() -> [AudioProcess] {
        readCount += 1
        if !readings.isEmpty { lastReading = readings.removeFirst() }
        return lastReading
    }
}

@MainActor
private final class FakeMediaKeySender: MediaKeySender {
    var canSend = true
    private(set) var sendCount = 0
    func sendPlayPause() { sendCount += 1 }
}

@MainActor
private final class FakePlaybackStateTracker: PlaybackStateTracker {
    var pausedBundleIDs: Set<String>

    init(paused: Set<String> = []) {
        self.pausedBundleIDs = paused
    }

    func isKnownPaused(bundleID: String) -> Bool {
        pausedBundleIDs.contains(bundleID)
    }
}

@MainActor
private func makeController(
    readings: [[AudioProcess]],
    tracker: PlaybackStateTracker = FakePlaybackStateTracker(),
    enabled: Bool = true
) -> (MediaPlaybackController, FakeProcessProbe, FakeMediaKeySender) {
    let probe = FakeProcessProbe(readings)
    let sender = FakeMediaKeySender()
    let controller = MediaPlaybackController(
        probe: probe,
        keySender: sender,
        stateTracker: tracker,
        isEnabled: { enabled },
        verifyDelay: .milliseconds(1)
    )
    return (controller, probe, sender)
}

/// The verification runs on its own after the key: waits for it to settle
/// rather than for a fixed time that scheduling jitter could overrun.
@MainActor
private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}


@MainActor
struct MediaPlaybackControllerTests {

    // MARK: - Classification

    @Test("A process that plays and captures at once is a call, whatever its name")
    func simultaneousCaptureMeansCommunication() {
        #expect(classify(call(1, "com.unknown.newapp")) == .communication)
    }

    @Test("A listed communication bundle is a call even when it is not capturing")
    func listedBundleMeansCommunication() {
        #expect(classify(player(1, "com.apple.FaceTime")) == .communication)
    }

    @Test("A plain player, and one with no bundle ID, are players")
    func everythingElseIsAPlayer() {
        #expect(classify(player(1)) == .player)
        #expect(classify(AudioProcess(pid: 1, bundleID: nil, capture: .none)) == .player)
    }

    @Test("Capturing other apps' audio with no microphone open is a relay, not a call")
    func appAudioCaptureIsARelay() {
        // A volume mixer runs input and output whenever music plays; read as a
        // call, it kept Mynah from ever pausing the music.
        #expect(classify(relay(1)) == .relay)
    }

    @Test("A listed communication app stays a call whatever it captures")
    func listedBundleWinsOverRelay() {
        #expect(classify(relay(1, "us.zoom.xos")) == .communication)
    }

    // MARK: - Ignored sources

    @Test("The system sound daemon is never a player: our own cues play under its PID")
    func systemSoundDaemonIsIgnored() {
        // AudioServicesPlayAlertSound renders the dictation cues out of process,
        // so they surface as a process that started mid-dictation and made the
        // controller undo the pause it had just made correctly.
        #expect(isIgnoredSource(bundleID: "systemsoundserverd", ownBundleID: "com.mynah.app"))
    }

    @Test("A second Mynah instance is ignored, a real player is not")
    func ownBundleIsIgnoredButPlayersAreNot() {
        #expect(isIgnoredSource(bundleID: "com.mynah.app", ownBundleID: "com.mynah.app"))
        #expect(!isIgnoredSource(bundleID: "com.spotify.client", ownBundleID: "com.mynah.app"))
        #expect(!isIgnoredSource(bundleID: nil, ownBundleID: "com.mynah.app"))
    }

    // MARK: - Pause decision

    @Test("Nothing playing: no media key is ever sent")
    func silentSystemSendsNothing() async {
        // The regression that started this: a player open but paused feeds no
        // output, so it must stay invisible and never be woken up.
        let (controller, _, sender) = makeController(readings: [[]])
        controller.pauseForRecording()
        #expect(controller.didPause == false)
        #expect(sender.sendCount == 0)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 0)
    }

    @Test("A call in progress: nothing is touched at all")
    func callIsLeftAlone() async {
        let (controller, _, sender) = makeController(readings: [[call(42)]])
        controller.pauseForRecording()
        #expect(controller.didPause == false)
        #expect(sender.sendCount == 0)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 0)
    }

    @Test("A call alongside music: the call wins, the music keeps playing")
    func callWinsOverMusic() async {
        let (controller, _, sender) = makeController(readings: [[player(10), call(42)]])
        controller.pauseForRecording()
        await controller.resumeAfterRecording().value

        #expect(controller.didPause == false)
        #expect(sender.sendCount == 0)
    }

    @Test("Music playing: pause then resume")
    func musicIsPausedAndResumed() async {
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        controller.pauseForRecording()
        #expect(controller.didPause == true)
        #expect(sender.sendCount == 1)

        await controller.resumeAfterRecording().value
        #expect(controller.didPause == false)
        #expect(sender.sendCount == 2)
    }

    @Test("A relay alongside music: the music is paused and resumed")
    func relayDoesNotHoldBackThePause() async {
        let (controller, _, sender) = makeController(readings: [[relay(5), player(10)], [relay(5), player(10)]])
        controller.pauseForRecording()
        #expect(controller.didPause == true)
        #expect(sender.sendCount == 1)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 2)
    }

    @Test("A relay alone is not something playing: no key is sent")
    func relayAloneSendsNothing() async {
        // Its output is another app's audio; on its own, the key would start
        // whatever paused player is the now-playing app.
        let (controller, _, sender) = makeController(readings: [[relay(5)]])
        controller.pauseForRecording()
        await controller.resumeAfterRecording().value

        #expect(controller.didPause == false)
        #expect(sender.sendCount == 0)
    }

    @Test("A relay that reads as capturing once our mic opens is not a woken player")
    func relayAfterMicOpensIsNotASpuriousStart() async {
        // The verification runs with our own microphone open, so the relay's
        // capture now reads as a microphone one. It was outputting all along.
        let (controller, _, sender) = makeController(
            readings: [[relay(5), player(10)], [AudioProcess(pid: 5, bundleID: "com.vorssaint.utils", capture: .microphone), player(10)]]
        )
        controller.pauseForRecording()
        await controller.resumeAfterRecording().value

        #expect(sender.sendCount == 2)
    }

    @Test("A player whose audio unit lingers after the pause is still resumed")
    func lingeringOutputStillResumes() async {
        // Spotify keeps its output running for seconds after a pause. Demanding
        // proof of silence would strand the music paused forever.
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        controller.pauseForRecording()
        await controller.resumeAfterRecording().value

        #expect(sender.sendCount == 2)
    }

    // MARK: - Self-correction

    @Test("The key woke a paused player instead: the toggle is undone and no resume follows")
    func spuriousStartIsUndone() async {
        // The browser was playing, but the key was routed to a paused Spotify,
        // which starts. pid 99 was silent before and is playing now.
        let (controller, _, sender) = makeController(
            readings: [[player(10, "com.google.Chrome")], [player(10, "com.google.Chrome"), player(99)]]
        )
        controller.pauseForRecording()
        #expect(sender.sendCount == 1)

        await controller.resumeAfterRecording().value
        // One key to pause, one to undo — and no third key on resume.
        #expect(sender.sendCount == 2)
        #expect(controller.didPause == false)
    }

    @Test("The same processes playing after the key does not count as a spurious start")
    func unchangedProcessesAreNotASpuriousStart() async {
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        controller.pauseForRecording()
        await controller.resumeAfterRecording().value

        #expect(sender.sendCount == 2)
    }

    // MARK: - Guards

    @Test("Setting disabled: the probe is never even read")
    func disabledSettingIsInert() async {
        let (controller, probe, sender) = makeController(readings: [[player(10)]], enabled: false)
        controller.pauseForRecording()
        await controller.resumeAfterRecording().value

        #expect(probe.readCount == 0)
        #expect(sender.sendCount == 0)
        #expect(controller.didPause == false)
    }

    @Test("Resume called twice sends a single play key")
    func doubleResumeIsIdempotent() async {
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        controller.pauseForRecording()
        await controller.resumeAfterRecording().value
        await controller.resumeAfterRecording().value

        #expect(sender.sendCount == 2)
    }

    @Test("A dictation started while the last resume awaits the check keeps the music paused")
    func resumeOvertakenByNextDictationStaysSilent() async {
        // A ends inside the verification window and B starts right after: A's
        // resume, still waiting, must not bring the music back in B.
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        controller.pauseForRecording()
        let resumeOfA = controller.resumeAfterRecording()
        controller.pauseForRecording()

        await resumeOfA.value
        #expect(sender.sendCount == 1)
        #expect(controller.didPause == true)
        #expect(controller.pauseStatus == .paused)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 2)
        #expect(controller.pauseStatus == .idle)
    }

    @Test("A warning from the last dictation does not carry over to the next")
    func blockedStatusDoesNotLeakIntoNextDictation() async {
        let (controller, _, sender) = makeController(readings: [[player(10)], []])
        sender.canSend = false
        controller.pauseForRecording()
        #expect(controller.pauseStatus == .blocked)

        // The next one starts before the last resume has run.
        controller.resumeAfterRecording()
        controller.pauseForRecording()
        #expect(controller.pauseStatus == .idle)
    }

    @Test("Resume without a preceding pause does nothing")
    func resumeWithoutPauseIsNoOp() async {
        let (controller, probe, sender) = makeController(readings: [[]])
        await controller.resumeAfterRecording().value

        #expect(probe.readCount == 0)
        #expect(sender.sendCount == 0)
    }

    @Test("A dictation starting while a pause is owed does not re-toggle the key")
    func standingDebtPreventsBlindRetoggle() async {
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        controller.pauseForRecording()
        #expect(sender.sendCount == 1)

        // Second dictation before any resume ran: the media is already paused by
        // us, so the key must stay untouched or it would start the music.
        controller.pauseForRecording()
        #expect(controller.didPause == true)
        #expect(sender.sendCount == 1)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 2)
    }

    // MARK: - Known paused players

    @Test("A player known to be paused is ignored even if CoreAudio reports lingering output")
    func knownPausedPlayerSendsNothing() async {
        let tracker = FakePlaybackStateTracker(paused: ["com.spotify.client"])
        let (controller, _, sender) = makeController(
            readings: [[player(10, "com.spotify.client")]],
            tracker: tracker
        )
        controller.pauseForRecording()
        #expect(controller.didPause == false)
        #expect(sender.sendCount == 0)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 0)
    }

    @Test("A known paused player does not prevent another active player from being paused")
    func knownPausedAlongsideActivePausesActive() async {
        let tracker = FakePlaybackStateTracker(paused: ["com.spotify.client"])
        let (controller, _, sender) = makeController(
            readings: [[player(10, "com.spotify.client"), player(20, "com.google.Chrome")]],
            tracker: tracker
        )
        controller.pauseForRecording()
        #expect(controller.didPause == true)
        #expect(sender.sendCount == 1)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 2)
    }

    // MARK: - Indicator

    @Test("A pause is shown once the key is verified, and cleared by the resume")
    func confirmedPauseIsShownUntilResume() async {
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        controller.pauseForRecording()
        // Not before the check: the key may yet have to be undone.
        #expect(controller.pauseStatus == .idle)

        #expect(await eventually { controller.pauseStatus == .paused })

        await controller.resumeAfterRecording().value
        #expect(controller.pauseStatus == .idle)
        #expect(sender.sendCount == 2)
    }

    @Test("A pause undone by the verification is never shown")
    func undonePauseIsNeverShown() async {
        let (controller, _, sender) = makeController(
            readings: [[player(10, "com.google.Chrome")], [player(10, "com.google.Chrome"), player(99)]]
        )
        controller.pauseForRecording()

        #expect(await eventually { sender.sendCount == 2 })
        #expect(controller.pauseStatus == .idle)
    }

    // MARK: - No Accessibility

    @Test("Without Accessibility: no key, no claimed pause, a warning until the resume")
    func missingPermissionIsReportedNotFaked() async {
        // The system drops the key silently, and players keep their output
        // alive after a pause: the verification would have confirmed it.
        let (controller, _, sender) = makeController(readings: [[player(10)], [player(10)]])
        sender.canSend = false
        controller.pauseForRecording()

        #expect(sender.sendCount == 0)
        #expect(controller.didPause == false)
        #expect(controller.pauseStatus == .blocked)

        await controller.resumeAfterRecording().value
        #expect(sender.sendCount == 0)
        #expect(controller.pauseStatus == .idle)
    }

    @Test("Without Accessibility and nothing playing: nothing to warn about")
    func missingPermissionWithNothingPlayingStaysQuiet() async {
        let (controller, _, sender) = makeController(readings: [[]])
        sender.canSend = false
        controller.pauseForRecording()

        #expect(controller.pauseStatus == .idle)
    }
}
