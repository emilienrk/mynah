// HotkeyManagerTests.swift
// MynahTests
//
// Tests for CGEventTap interception logic (handleRawEvent)
// using synthetic CGEvents — no real tap is installed.

import Testing
import AppKit
import CoreGraphics

@MainActor
struct HotkeyManagerTests {

    private func keyEvent(_ keyCode: Int, down: Bool, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: CGKeyCode(keyCode),
            keyDown: down
        )!
        event.flags = flags
        return event
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { cont.resume() }
        }
    }

    // MARK: - Bug 1: Plain space broken when ⌥Space is bound

    @Test("Plain space passes through tap when ⌥Space is bound (no active recording)")
    func plainSpacePassesThroughWhenComboBound() {
        let manager = HotkeyManager()
        manager.updateHotKey(HotKey(keyCode: 49, modifiers: Int(CGEventFlags.maskAlternate.rawValue)))

        let down = manager.handleRawEvent(type: .keyDown, event: keyEvent(49, down: true))
        let up   = manager.handleRawEvent(type: .keyUp,   event: keyEvent(49, down: false))

        #expect(down != nil, "keyDown for plain space must not be consumed")
        #expect(up != nil, "keyUp for plain space must not be consumed")
    }

    @Test("Unstick keyUp is only swallowed if a hotkey press was engaged")
    func unstickReleaseOnlyWhenEngaged() {
        let manager = HotkeyManager()
        manager.updateHotKey(HotKey(keyCode: 49, modifiers: Int(CGEventFlags.maskAlternate.rawValue)))

        // ⌥Space pressed → consumed, press engaged.
        let down = manager.handleRawEvent(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate))
        #expect(down == nil)

        // ⌥ released before Space: the keyUp for Space (no mods) must be
        // consumed to end the recording (unstick safeguard).
        let unstick = manager.handleRawEvent(type: .keyUp, event: keyEvent(49, down: false))
        #expect(unstick == nil)

        // Subsequent plain Space press: nothing engaged → must pass through.
        let later = manager.handleRawEvent(type: .keyUp, event: keyEvent(49, down: false))
        #expect(later != nil)
    }

    // MARK: - Bug 2/3: Dictation key (keycode 176)

    @Test("Default hotkey is dictation key (176), not Mission Control (160)")
    func defaultHotKeyIsDictationKey() {
        #expect(HotKey.defaultHotKey.keyCode == 176)
        #expect(HotKey.defaultHotKey.modifiers == 0)
        let name = HotKey.defaultHotKey.displayString
        #expect(name.contains("Dictée") || name.contains("Dictation"))
    }

    @Test("Bound dictation key is consumed (Apple dictation must not receive it)")
    func dictationKeyConsumedWhenBound() {
        let manager = HotkeyManager()
        manager.updateHotKey(.defaultHotKey)

        let down = manager.handleRawEvent(type: .keyDown, event: keyEvent(176, down: true))
        let up   = manager.handleRawEvent(type: .keyUp,   event: keyEvent(176, down: false))

        #expect(down == nil, "keyDown for dictation key must be consumed")
        #expect(up == nil, "keyUp for dictation key must be consumed")
    }

    // MARK: - Autorepeat in toggle mode

    @Test("Autorepeated hotkey events do not retrigger (toggle mode)")
    func autorepeatDoesNotRetrigger() async {
        let manager = HotkeyManager()
        manager.updateHotKey(HotKey(keyCode: 49, modifiers: 0))
        manager.setMode(.toggle)

        let counter = Counter()
        manager.onKeyDown = { counter.downs += 1 }
        manager.onKeyUp   = { counter.ups += 1 }

        _ = manager.handleRawEvent(type: .keyDown, event: keyEvent(49, down: true))

        let repeatEvent = keyEvent(49, down: true)
        repeatEvent.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        let r1 = manager.handleRawEvent(type: .keyDown, event: repeatEvent)
        let r2 = manager.handleRawEvent(type: .keyDown, event: repeatEvent)

        await drainMainQueue()

        #expect(r1 == nil && r2 == nil, "hotkey repeats remain consumed")
        #expect(counter.downs == 1, "single trigger despite repeat events")
        #expect(counter.ups == 0, "toggle must not stop on a repeat event")
    }

    // MARK: - Hotkey capture via event tap

    @Test("Capture grabs key+modifiers combination and consumes event")
    func captureGrabsComboAndConsumes() async {
        let manager = HotkeyManager()
        let box = CapturedBox()

        manager.beginHotKeyCapture { box.value = $0; box.called = true }
        let result = manager.handleRawEvent(type: .keyDown, event: keyEvent(49, down: true, flags: .maskAlternate))

        await drainMainQueue()

        #expect(result == nil, "captured event must be consumed")
        #expect(box.called)
        #expect(box.value == HotKey(keyCode: 49, modifiers: Int(CGEventFlags.maskAlternate.rawValue)))
    }

    @Test("Escape cancels capture")
    func escapeCancelsCapture() async {
        let manager = HotkeyManager()
        let box = CapturedBox()

        manager.beginHotKeyCapture { box.value = $0; box.called = true }
        let result = manager.handleRawEvent(type: .keyDown, event: keyEvent(53, down: true))

        await drainMainQueue()

        #expect(result == nil)
        #expect(box.called)
        #expect(box.value == nil)
    }

    @Test("Standalone modifier is captured on release")
    func captureLoneModifierOnRelease() async {
        let manager = HotkeyManager()
        let box = CapturedBox()

        manager.beginHotKeyCapture { box.value = $0; box.called = true }

        // fn (63) pressed then released.
        let fnDown = keyEvent(63, down: true)
        fnDown.flags = .maskSecondaryFn
        let downResult = manager.handleRawEvent(type: .flagsChanged, event: fnDown)
        #expect(downResult == nil)

        let fnUp = keyEvent(63, down: false)
        fnUp.flags = []
        let upResult = manager.handleRawEvent(type: .flagsChanged, event: fnUp)

        await drainMainQueue()

        #expect(upResult == nil)
        #expect(box.called)
        #expect(box.value == HotKey(keyCode: 63, modifiers: 0))
    }

    @Test("Previous hotkey does not fire recording during capture")
    func oldHotkeyDoesNotFireDuringCapture() async {
        let manager = HotkeyManager()
        manager.updateHotKey(HotKey(keyCode: 49, modifiers: 0))

        let counter = Counter()
        manager.onKeyDown = { counter.downs += 1 }

        let box = CapturedBox()
        manager.beginHotKeyCapture { box.value = $0; box.called = true }

        _ = manager.handleRawEvent(type: .keyDown, event: keyEvent(49, down: true))
        await drainMainQueue()

        #expect(counter.downs == 0, "key must be captured, not triggered")
        #expect(box.value == HotKey(keyCode: 49, modifiers: 0))
    }

    /// Without Accessibility permission, the tap cannot be installed: it must
    /// fall back to polling, otherwise the hotkey remains inactive until relaunch.
    @MainActor
    @Test("startListening without Accessibility falls back to polling",
          .enabled(if: !AXIsProcessTrusted()))
    func startListeningDefersToPolling() {
        let manager = HotkeyManager()
        defer { manager.stopPollingAccessibility() }

        manager.startListening()

        #expect(manager.isListening == false)
        #expect(manager.accessibilityPollTask != nil)
    }
}

// MARK: - Helpers

@MainActor
private final class Counter {
    var downs = 0
    var ups = 0
}

@MainActor
private final class CapturedBox {
    var value: HotKey?
    var called = false
}
