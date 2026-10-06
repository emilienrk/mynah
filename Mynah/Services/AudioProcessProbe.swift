// AudioProcessProbe.swift
// Mynah
//
// Reports which processes are currently feeding the audio output, so the media
// controller can tell "Spotify is playing" from "a call is running" from
// "nothing at all".
//
// The device-level kAudioDevicePropertyDeviceIsRunningSomewhere cannot make
// that distinction. It answers "is any sound coming out": true during a call,
// and false for a player that is open but paused. Acting on that answer meant
// sending the Play/Pause key during a call, where it reached whatever paused
// player was the system's now-playing app and started it.

import Foundation
import CoreAudio

/// What a process records while it plays.
enum InputCapture: Equatable {
    case none
    /// Recording while a microphone is open somewhere. CoreAudio only says a
    /// device is in use, not by whom, so this is the best reading available.
    case microphone
    /// Recording with no microphone open anywhere: the input is other apps'
    /// audio, read through a process tap.
    case appAudio
}

struct AudioProcess: Equatable {
    let pid: pid_t
    let bundleID: String?
    let capture: InputCapture
}

@MainActor
protocol AudioProcessProbe {
    /// Processes running an output stream right now, ours excluded.
    func outputtingProcesses() -> [AudioProcess]
}

enum AudioSourceKind {
    case communication
    case player
    /// Plays back what it taps from other apps — a per-app volume mixer, a
    /// visualiser. Not a source of its own, and not a conversation either.
    case relay
}

/// Communication apps must never be interrupted, so anything that looks like
/// one is left alone.
///
/// The primary signal is behavioural rather than a name: a process that plays
/// *and* records from a microphone at the same time is holding a conversation,
/// not playing music. That covers apps nobody listed — a Google Meet in a
/// browser tab included, which no bundle ID could ever catch since it shares
/// its process with YouTube.
///
/// Recording alone is not that signal. A per-app volume mixer taps every app's
/// audio and plays it back, so it runs input and output whenever music plays;
/// read as a call, it made Mynah abstain exactly when there was music to
/// pause. A tap opens no microphone, which is what sets the two apart.
///
/// The name list is a fallback for the case the behavioural signal misses:
/// Apple routes FaceTime audio through daemons, and the daemon that plays the
/// remote party is not necessarily the one holding the microphone.
///
/// Over-approximating here is safe. Calling a player a communication app only
/// ever makes Mynah abstain; it can never make it act wrongly.
func classify(_ process: AudioProcess) -> AudioSourceKind {
    if process.capture == .microphone { return .communication }
    if let bundleID = process.bundleID, communicationBundleIDs.contains(bundleID) { return .communication }
    return process.capture == .appAudio ? .relay : .player
}

/// The daemon macOS renders alert sounds through — Mynah's own dictation
/// cues included, since `AudioServicesPlayAlertSound` plays them out of
/// process, under a PID no ownership check can recognise as ours.
///
/// Reported by CoreAudio as the process name rather than a reverse-DNS bundle
/// identifier; read off the running system.
private let systemSoundDaemonBundleID = "systemsoundserverd"

/// Whether a process seen on the output must be skipped instead of counted as
/// a player.
///
/// Letting the sound daemon through is what broke the feature: the cue starts
/// right after the media key is sent, so the verification saw a process that
/// was silent before and playing after, read it as "the key woke a paused
/// player", and undid a pause that was correct.
func isIgnoredSource(bundleID: String?, ownBundleID: String?) -> Bool {
    if bundleID == systemSoundDaemonBundleID { return true }
    // A second copy of Mynah — a build running next to the installed app —
    // plays the same sounds, and a PID check cannot see it. Taking it for a
    // player sends Play/Pause into a silent system, which *starts* music
    // rather than stopping it.
    return bundleID != nil && bundleID == ownBundleID
}

private let communicationBundleIDs: Set<String> = [
    // Verified against the bundles installed on the build machine.
    "com.apple.FaceTime",
    "com.hnc.Discord",
    "com.microsoft.teams2",
    // Observed in the process list on this machine; these daemons carry the
    // audio of FaceTime and Continuity calls rather than the app itself.
    "com.apple.avconferenced",
    "com.apple.TelephonyUtilities",
    "com.apple.callservicesd",
    // Not installed here, so these are the published identifiers rather than
    // ones read off a bundle. An identifier that turns out to be wrong simply
    // never matches, and the behavioural signal above still covers the app.
    "us.zoom.xos",
    "com.microsoft.teams",
    "com.tinyspeck.slackmacgap",
    "com.skype.skype",
    "Cisco-Systems.Spark",
]

// MARK: - Real implementation

/// Reads the per-process audio state published by the HAL. Available as public
/// API since macOS 14.4 and needs no entitlement or TCC prompt — only creating
/// a process *tap* to capture the samples would, and we never do that.
///
/// Any CoreAudio failure is reported as "not playing", keeping Mynah passive
/// when it cannot see clearly.
struct CoreAudioProcessProbe: AudioProcessProbe {

    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let ownBundleID = Bundle.main.bundleIdentifier

    func outputtingProcesses() -> [AudioProcess] {
        let microphoneOpen = isAnyMicrophoneOpen()

        return objectList(kAudioHardwarePropertyProcessObjectList).compactMap { object in
            guard readUInt32(object, kAudioProcessPropertyIsRunningOutput) == 1,
                  let pid = readPID(object),
                  // Our own confirmation sound would otherwise read as a player.
                  pid != ownPID
            else { return nil }

            let bundleID = readString(object, kAudioProcessPropertyBundleID)
            guard !isIgnoredSource(bundleID: bundleID, ownBundleID: ownBundleID) else { return nil }

            let capture: InputCapture = if readUInt32(object, kAudioProcessPropertyIsRunningInput) != 1 {
                .none
            } else {
                microphoneOpen ? .microphone : .appAudio
            }
            return AudioProcess(pid: pid, bundleID: bundleID, capture: capture)
        }
    }

    /// Whether any device that records is in use. Read at the device level, so
    /// a device that both records and plays counts as open while it only plays:
    /// the error falls on the safe side, a relay taken for a call.
    private func isAnyMicrophoneOpen() -> Bool {
        objectList(kAudioHardwarePropertyDevices).contains { device in
            hasInputStreams(device) && readUInt32(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
        }
    }

    private func hasInputStreams(_ device: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private func objectList(_ selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var address = propertyAddress(selector)
        let system = AudioObjectID(kAudioObjectSystemObject)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }

        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    private func readUInt32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private func readPID(_ object: AudioObjectID) -> pid_t? {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    /// Read through a byte buffer rather than a `CFString?` inout: taking the
    /// address of an optional object reference is not a valid way to receive a
    /// +1 CFString from CoreAudio.
    private func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size == UInt32(MemoryLayout<CFString>.size)
        else { return nil }

        var buffer = [UInt8](repeating: 0, count: Int(size))
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &buffer) == noErr else { return nil }

        // CoreAudio hands back a +1 reference the caller owns, so consume it
        // rather than loading it as a managed CFString, which would retain a
        // second time and leak the original.
        let unmanaged = buffer.withUnsafeBytes { $0.load(as: Unmanaged<CFString>.self) }
        return unmanaged.takeRetainedValue() as String
    }

    private func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
