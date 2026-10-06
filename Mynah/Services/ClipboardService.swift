// ClipboardService.swift
// Mynah
//
// Writes transcribed text to the clipboard and optionally simulates Cmd+V
// using CGEvent (requires Accessibility permission).
// Falls back to a macOS notification when paste is not possible.

import AppKit
import ApplicationServices
import os
import UserNotifications

private let logger = Logger(category: "Clipboard")

// MARK: - Paste Result

enum PasteResult {
    /// Text was both copied and pasted into the active app.
    case pasted
    /// Text was copied only (Accessibility unavailable or paste failed).
    case copiedOnly
}

// MARK: - Focus State

/// What the Accessibility API can say about the focused element.
enum FocusState {
    case editable
    case notEditable
    /// Nothing usable exposed. Electron apps and web views can report this for
    /// a perfectly good text field, but so does an app with no field at all —
    /// the paste treats it as no field.
    case unknown
}

/// Reads the system-wide focused element. Only an element that is present *and*
/// clearly not editable answers `notEditable`; anything unreadable is `unknown`.
@MainActor
func systemFocusState() -> FocusState {
    let system = AXUIElementCreateSystemWide()
    var focused: CFTypeRef?
    guard AXUIElementCopyAttributeValue(
        system, kAXFocusedUIElementAttribute as CFString, &focused
    ) == .success, let focused else { return .unknown }

    guard CFGetTypeID(focused) == AXUIElementGetTypeID() else { return .unknown }
    let element = unsafeBitCast(focused, to: AXUIElement.self)

    var settable: DarwinBoolean = false
    if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
       settable.boolValue {
        return .editable
    }

    var role: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success,
          let roleName = role as? String else { return .unknown }

    let editableRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField", "AXWebArea"
    ]
    return editableRoles.contains(roleName) ? .editable : .notEditable
}

// MARK: - Chromium & Electron

/// Chromium and Electron build their accessibility tree only when asked, and
/// until then report no focused element at all: a real text field and no field
/// look the same, and the paste goes out blind. `AXManualAccessibility` is the
/// request Electron documents for assistive apps. The tree is built
/// asynchronously, so this runs when the dictation starts, not at paste time;
/// the mode then sticks for the app's lifetime.
@MainActor
enum AccessibilityWaker {
    private static var checked: Set<pid_t> = []

    static func wakeFrontmostApp() {
        guard AXIsProcessTrusted(),
              let app = NSWorkspace.shared.frontmostApplication,
              checked.insert(app.processIdentifier).inserted
        else { return }
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"

        Task.detached(priority: .utility) {
            let element = AXUIElementCreateApplication(pid)
            // Served on the target's main thread: a hung app must not hold the dictation.
            AXUIElementSetMessagingTimeout(element, 1.5)
            var focused: CFTypeRef?
            // Apps that already answer — native ones, or one VoiceOver woke — are left alone.
            guard AXUIElementCopyAttributeValue(
                element, kAXFocusedUIElementAttribute as CFString, &focused
            ) == .noValue else { return }
            let result = AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            logger.info("Accessibility wake of \(name, privacy: .public): \(result.rawValue, privacy: .public)")
        }
    }
}

// MARK: - ClipboardService

/// Copies text to the general pasteboard and optionally auto-pastes it.
@MainActor
final class ClipboardService {

    // MARK: - Properties

    /// When `true`, the service will attempt to simulate Cmd+V after copying.
    var autoPasteEnabled: Bool = true

    private let pasteboard: NSPasteboard
    private let focusState: @MainActor () -> FocusState
    private let notifyCopied: @MainActor () async -> Void

    init(
        pasteboard: NSPasteboard = .general,
        focusState: @escaping @MainActor () -> FocusState = systemFocusState,
        notifyCopied: @escaping @MainActor () async -> Void = sendCopiedNotification
    ) {
        self.pasteboard = pasteboard
        self.focusState = focusState
        self.notifyCopied = notifyCopied
    }

    // MARK: - Public API

    /// Main entry point: copies `text` then pastes if `autoPasteEnabled`.
    ///
    /// - Returns: `.pasted` if the full paste succeeded, `.copiedOnly` otherwise.
    @discardableResult
    func copyAndPaste(_ text: String) async -> PasteResult {
        // Pasting only borrows the pasteboard — whatever the user had copied is
        // handed back once the target app has read the transcription.
        let previousItems = snapshotPasteboard()

        // 1. Write to the pasteboard.
        let changeCount = copyToClipboard(text)

        // 2. Attempt auto-paste if requested, and only into a field we can see.
        // A blind paste into an app that describes nothing — Brave with no field
        // selected, the Desktop — lands nowhere, yet reads as "pasted" and puts
        // the clipboard back: the text is lost. Copying it instead costs a ⌘V
        // in the apps that hide a real field, and loses nothing.
        let focus = autoPasteEnabled && AXIsProcessTrusted() ? focusState() : nil
        if let focus { logger.info("Focused element: \(String(describing: focus), privacy: .public)") }
        if focus == .editable {
            let success = await simulatePaste()
            if success {
                // The target app reads the pasteboard on its own run loop; restoring
                // too early makes it paste the previous content instead.
                try? await Task.sleep(for: .milliseconds(300))
                restorePasteboard(previousItems, ifUnchangedSince: changeCount)
                return .pasted
            }
        }

        // 3. Fallback: notify user. The text stays on the pasteboard — that is the
        // whole point of the fallback, so nothing is restored here.
        if autoPasteEnabled {
            await notifyCopied()
        }
        return .copiedOnly
    }

    /// Writes text to the pasteboard (does NOT paste).
    ///
    /// - Returns: the resulting `changeCount`, to detect later writes by other apps.
    @discardableResult
    func copyToClipboard(_ text: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    // MARK: - Pasteboard save & restore

    /// Detached copy of the current contents — the originals are invalidated by
    /// the next `clearContents()`, so every type has to be copied out eagerly.
    func snapshotPasteboard() -> [NSPasteboardItem] {
        guard let items = pasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy.types.isEmpty ? nil : copy
        }
    }

    /// Puts `items` back, unless another app wrote to the pasteboard meanwhile —
    /// restoring then would silently destroy what the user just copied.
    func restorePasteboard(_ items: [NSPasteboardItem], ifUnchangedSince changeCount: Int) {
        guard pasteboard.changeCount == changeCount else { return }
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    // MARK: - Accessibility check

    /// Whether the process has Accessibility permission (required for auto-paste).
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Private implementation

    /// Simulates ⌘V by posting keyDown + keyUp CGEvents to the HID event source.
    /// Must be called after the text is already in the pasteboard.
    ///
    /// - Returns: `true` if events were posted without error.
    private func simulatePaste() async -> Bool {
        // Small delay: let the system register the key release before injecting Cmd+V.
        // Without this, some apps (e.g. Terminal) might not receive the paste.
        try? await Task.sleep(for: .milliseconds(80))

        // CGEvent.post must NOT run on the AVFoundation realtime thread (RealtimeMessenger).
        // We use DispatchQueue.main to guarantee a safe, deterministic posting thread.
        return await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                guard let source = CGEventSource(stateID: .hidSystemState) else {
                    continuation.resume(returning: false)
                    return
                }

                let vKeyCode: CGKeyCode = 9 // kVK_ANSI_V

                guard
                    let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
                    let keyUp   = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
                else {
                    continuation.resume(returning: false)
                    return
                }

                keyDown.flags = .maskCommand
                keyUp.flags   = .maskCommand

                keyDown.post(tap: .cgSessionEventTap)
                keyUp.post(tap: .cgSessionEventTap)

                continuation.resume(returning: true)
            }
        }
    }
}

// MARK: - Copied notification

/// Tells the user the text is waiting on the clipboard.
@MainActor
func sendCopiedNotification() async {
    await NotificationService.shared.sendCopiedNotification()
}
