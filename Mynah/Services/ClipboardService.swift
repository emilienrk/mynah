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

/// The app a dictation was meant for, taken when the paste is decided: by the
/// time anyone acts on the result, the indicator may have taken the front.
struct PasteTarget: Equatable, Sendable {
    let bundleID: String
    let name: String
}

enum PasteResult: Equatable {
    /// Text was both copied and pasted into the active app.
    case pasted
    /// ⌘V was sent to an app on the always-paste list with no field in sight.
    /// It may have landed nowhere, so the text was left on the pasteboard.
    case pastedUnverified
    /// Text was copied only (Accessibility unavailable or paste failed). Carries
    /// the app it was meant for when that app can go on the always-paste list.
    case copiedOnly(PasteTarget?)
}

/// What to do with the transcription once it is on the pasteboard.
enum PasteDecision: Equatable {
    /// A field is in sight: paste, then hand the user's clipboard back.
    case pasteAndRestore
    /// The user vouched for the app, not the field: the text stays on the
    /// pasteboard in case the paste landed nowhere.
    case pasteAndKeep
    case copyOnly

    init(focus: FocusState, alwaysPaste: Bool) {
        switch focus {
        case .editable:              self = .pasteAndRestore
        case .notEditable, .unknown: self = alwaysPaste ? .pasteAndKeep : .copyOnly
        }
    }
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

/// What one element says about itself, as far as taking text goes.
struct AXElementTraits: Equatable {
    /// Nil when it could not be read.
    var role: String?
    var isValueSettable = false
    /// Set by web content on every node inside an editable region.
    var hasEditableAncestor = false
}

enum FocusClassifier {
    static let textRoles: Set<String> = [
        kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"
    ]
    /// Roles that take no text themselves but can sit inside a field that does.
    static let passiveRoles: Set<String> = [kAXStaticTextRole, kAXGroupRole, kAXUnknownRole]
    /// Past these, an ancestor's editability says nothing about the focused node.
    static let boundaryRoles: Set<String> = [
        "AXWebArea", kAXScrollAreaRole, kAXWindowRole, kAXApplicationRole
    ]
    static let maxAncestors = 4

    /// `ancestors` is walked lazily, nearest first, and only for a passive node.
    static func state(focused: AXElementTraits, ancestors: some Sequence<AXElementTraits>) -> FocusState {
        if focused.isValueSettable || focused.hasEditableAncestor { return .editable }
        guard let role = focused.role else { return .unknown }
        // WebKit reports the web area when no field has focus, so this pastes
        // into nothing there. Kept until a Chromium web field reported on its
        // web area is ruled out.
        if textRoles.contains(role) || role == "AXWebArea" { return .editable }
        guard passiveRoles.contains(role) else { return .notEditable }

        // Only the strong signals here: Chromium marks most of its nodes
        // value-settable, so that one would make any static text a field.
        for ancestor in ancestors.prefix(maxAncestors) {
            guard let role = ancestor.role, !boundaryRoles.contains(role) else { break }
            if ancestor.hasEditableAncestor || textRoles.contains(role) { return .editable }
        }
        return .notEditable
    }
}

/// Reads the focused element, system-wide or else from the frontmost app. Only
/// an element that is present *and* clearly not editable answers `notEditable`;
/// anything unreadable is `unknown`.
@MainActor
func systemFocusState() -> FocusState {
    guard let focused = focusedElement() else { return .unknown }
    return FocusClassifier.state(focused: AXElementTraits(focused), ancestors: AXAncestors(of: focused))
}

@MainActor
private func focusedElement() -> AXUIElement? {
    let system = AXUIElementCreateSystemWide()
    // Set on the system-wide element, this is the default for every element of
    // the process: a hung target app must not freeze the main actor.
    AXUIElementSetMessagingTimeout(system, 0.25)
    var focused: CFTypeRef?
    let error = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused)
    if error == .success, let element = axElement(focused) { return element }

    // A timeout means the app is not answering; asking it again would only wait twice.
    guard error != .cannotComplete,
          let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
    else { return nil }
    return copyElement(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
}

private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)
}

private func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return axElement(value)
}

extension AXElementTraits {
    init(_ element: AXUIElement) {
        var settable: DarwinBoolean = false
        isValueSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
            && settable.boolValue

        var role: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role) == .success {
            self.role = role as? String
        }
        hasEditableAncestor = ["AXEditableAncestor", "AXHighestEditableAncestor"].contains {
            copyElement(element, $0) != nil
        }
    }
}

/// The parent chain, read one element at a time and only as far as it is walked.
private struct AXAncestors: Sequence, IteratorProtocol {
    private var element: AXUIElement

    init(of element: AXUIElement) {
        self.element = element
    }

    mutating func next() -> AXElementTraits? {
        guard let parent = copyElement(element, kAXParentAttribute) else { return nil }
        element = parent
        return AXElementTraits(parent)
    }
}

/// The frontmost app, unless it is Mynah itself — its own windows are no paste target.
@MainActor
func frontmostPasteTarget() -> PasteTarget? {
    guard let app = NSWorkspace.shared.frontmostApplication,
          let bundleID = app.bundleIdentifier,
          bundleID != Bundle.main.bundleIdentifier
    else { return nil }
    return PasteTarget(bundleID: bundleID, name: app.localizedName ?? bundleID)
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

    private let pasteboard: NSPasteboard
    private let focusState: @MainActor () -> FocusState
    private let focusSettleTime: Duration
    private let focusPollInterval: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private let pollWait: @MainActor (Duration) async -> Void
    private let frontmostApp: @MainActor () -> PasteTarget?
    /// Read at paste time, so toggling the setting applies without a relaunch.
    private let autoPasteEnabled: @MainActor () -> Bool
    private let alwaysPasteApps: @MainActor () -> Set<String>
    private let isTrusted: @MainActor () -> Bool
    private let sendPaste: @MainActor () async -> Bool
    private let notifyCopied: @MainActor () async -> Void

    init(
        pasteboard: NSPasteboard = .general,
        focusState: @escaping @MainActor () -> FocusState = systemFocusState,
        focusSettleTime: Duration = .milliseconds(400),
        focusPollInterval: Duration = .milliseconds(80),
        now: @escaping @MainActor () -> ContinuousClock.Instant = { .now },
        pollWait: @escaping @MainActor (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        frontmostApp: @escaping @MainActor () -> PasteTarget? = frontmostPasteTarget,
        autoPasteEnabled: @escaping @MainActor () -> Bool = { AppSettings.shared.autoPasteEnabled },
        alwaysPasteApps: @escaping @MainActor () -> Set<String> = { AppSettings.shared.alwaysPasteBundleIDs },
        isTrusted: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        sendPaste: @escaping @MainActor () async -> Bool = postPasteKeystroke,
        notifyCopied: @escaping @MainActor () async -> Void = sendCopiedNotification
    ) {
        self.pasteboard = pasteboard
        self.focusState = focusState
        self.focusSettleTime = focusSettleTime
        self.focusPollInterval = focusPollInterval
        self.now = now
        self.pollWait = pollWait
        self.frontmostApp = frontmostApp
        self.autoPasteEnabled = autoPasteEnabled
        self.alwaysPasteApps = alwaysPasteApps
        self.isTrusted = isTrusted
        self.sendPaste = sendPaste
        self.notifyCopied = notifyCopied
    }

    // MARK: - Public API

    /// Main entry point: copies `text` then pastes if `autoPasteEnabled`.
    ///
    /// - Returns: `.pasted` if the full paste succeeded, `.pastedUnverified` if
    ///   it went to an always-paste app blind, `.copiedOnly` otherwise.
    @discardableResult
    func copyAndPaste(_ text: String) async -> PasteResult {
        // Pasting only borrows the pasteboard — whatever the user had copied is
        // handed back once the target app has read the transcription.
        let previousItems = snapshotPasteboard()

        // 1. Write to the pasteboard.
        let changeCount = copyToClipboard(text)

        guard autoPasteEnabled() else { return .copiedOnly(nil) }
        guard isTrusted() else {
            await notifyCopied()
            return .copiedOnly(nil)
        }

        // 2. Attempt auto-paste only into a field we can see, or into an app the
        // user vouched for. A blind paste into an app that describes nothing —
        // Brave with no field selected, the Desktop — lands nowhere, yet reads as
        // "pasted" and puts the clipboard back: the text is lost. Copying it
        // instead costs a ⌘V in the apps that hide a real field, and loses nothing.
        let target = frontmostApp()
        let focus = await settledFocusState()
        let alwaysPaste = target.map { alwaysPasteApps().contains($0.bundleID) } ?? false
        logger.info("Focused element: \(String(describing: focus), privacy: .public), always paste: \(alwaysPaste, privacy: .public)")

        switch PasteDecision(focus: focus, alwaysPaste: alwaysPaste) {
        case .pasteAndRestore:
            if await sendPaste() {
                // The target app reads the pasteboard on its own run loop; restoring
                // too early makes it paste the previous content instead.
                try? await Task.sleep(for: .milliseconds(300))
                restorePasteboard(previousItems, ifUnchangedSince: changeCount)
                return .pasted
            }
        case .pasteAndKeep:
            if await sendPaste() { return .pastedUnverified }
        case .copyOnly:
            break
        }

        // 3. Fallback: notify user. The text stays on the pasteboard — that is the
        // whole point of the fallback, so nothing is restored here.
        await notifyCopied()
        return .copiedOnly(alwaysPaste ? nil : target)
    }

    /// Chromium and Electron build their tree asynchronously after the wake, so
    /// a short dictation can end before it is ready: `unknown` is asked again
    /// for a moment, a hard cap on waiting for another process, not for us.
    private func settledFocusState() async -> FocusState {
        let deadline = now() + focusSettleTime
        var focus = focusState()
        while focus == .unknown, now() < deadline {
            await pollWait(focusPollInterval)
            focus = focusState()
        }
        return focus
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
}

// MARK: - Paste keystroke

/// Simulates ⌘V by posting keyDown + keyUp CGEvents to the HID event source.
/// Must be called after the text is already in the pasteboard.
///
/// - Returns: `true` if events were posted without error.
@MainActor
func postPasteKeystroke() async -> Bool {
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

// MARK: - Copied notification

/// Tells the user the text is waiting on the clipboard.
@MainActor
func sendCopiedNotification() async {
    await NotificationService.shared.sendCopiedNotification()
}
