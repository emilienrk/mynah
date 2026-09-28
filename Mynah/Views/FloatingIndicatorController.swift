// FloatingIndicatorController.swift
// Mynah
//
// Owns the floating pill shown at the bottom of the screen during a dictation:
// maps pipeline states to what the pill says, places it, and fades it in and out.

import AppKit
import SwiftUI

/// What the pill shows. Outlives the pipeline state it came from: `.pasting`
/// lasts a few milliseconds and is followed by `.idle`, so the outcome has to
/// be held here long enough to be read.
enum FloatingIndicatorPhase: Equatable {
    case recording
    case transcribing
    case done(PasteResult?)
    /// Nowhere to paste: the text is shown so it is not lost from sight.
    case copied(String)
    case silent
    case error(String)
}

@MainActor
@Observable
final class FloatingIndicatorModel {
    var phase: FloatingIndicatorPhase = .recording
}

/// Never key: a key panel would take the keystrokes meant for the field the
/// dictation is pasted into.
final class FloatingIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class FloatingIndicatorController: NSObject, NSWindowDelegate {

    /// Larger than the pill, which SwiftUI anchors at the bottom centre: the
    /// pill changes width between phases without the window being resized.
    /// Transparent pixels let clicks through to what is underneath.
    private static let panelSize = NSSize(width: 420, height: 240)
    private static let bottomMargin: CGFloat = 12

    private let coordinator: RecordingCoordinator
    private let audioCapture: AudioCaptureService
    private let settings: AppSettings
    private let model = FloatingIndicatorModel()

    private var panel: FloatingIndicatorPanel?
    private var hideTask: Task<Void, Never>?
    private var previousState: PipelineState = .idle
    private var shownOutcomeID: Int?
    /// Set while the panel is placed by code, so only a drag by the user is saved.
    private var isPlacingPanel = false
    /// Bumped on every show and hide, so a fade-out overtaken by a new dictation
    /// does not order the panel out from under it.
    private var fadeGeneration = 0
    /// Whether the current phase goes away on its own; hovering holds it.
    private var autoHides = false

    init(coordinator: RecordingCoordinator, audioCapture: AudioCaptureService, settings: AppSettings = .shared) {
        self.coordinator = coordinator
        self.audioCapture = audioCapture
        self.settings = settings
        super.init()
    }

    func update(for state: PipelineState) {
        defer { previousState = state }

        guard settings.showFloatingIndicator else {
            // Not shown later either, if the indicator is switched back on.
            shownOutcomeID = coordinator.lastOutcome?.id
            hide(animated: false)
            return
        }

        switch state {
        case .loadingModel, .recording:
            show(.recording)

        case .transcribing:
            show(.transcribing)

        case .pasting:
            break

        case .idle:
            if let outcome = coordinator.lastOutcome, outcome.id != shownOutcomeID {
                shownOutcomeID = outcome.id
                show(outcome.kind)
            } else if case .error = previousState {
                // Already on its way out, on the error's own delay.
            } else {
                // Cancelled: the user asked for it to go, no need to linger.
                hide(animated: true)
            }

        case .error(let message):
            show(.error(message), hidingAfter: .seconds(2.6))
        }
    }

    // MARK: - Showing

    private func show(_ outcome: DictationOutcome.Kind) {
        switch outcome {
        case .silent:
            show(.silent, hidingAfter: .seconds(1.6))
        case .transcribed(let text, .copiedOnly) where settings.showTranscriptWhenNotPasted:
            show(.copied(text), hidingAfter: .seconds(8))
        case .transcribed(_, let result):
            show(.done(result), hidingAfter: .seconds(1.1))
        }
    }

    private func show(_ phase: FloatingIndicatorPhase, hidingAfter delay: Duration? = nil) {
        hideTask?.cancel()
        hideTask = nil

        let panel = panelCreatedIfNeeded()
        if panel.isVisible {
            withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                model.phase = phase
            }
        } else {
            // Not animated from whatever it showed last time: the fade-in
            // would reveal that content morphing away for a few frames.
            model.phase = phase
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        fadeGeneration += 1
        if !panel.isVisible {
            place(panel)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }

        autoHides = delay != nil
        if let delay { scheduleHide(after: delay) }
    }

    private func scheduleHide(after delay: Duration) {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.hide(animated: true)
        }
    }

    /// Holds an outcome on screen while the pointer is on it — the copied text
    /// may take longer to read than the delay allows.
    private func pointerHovered(_ isHovering: Bool) {
        guard autoHides else { return }
        if isHovering {
            hideTask?.cancel()
            hideTask = nil
        } else {
            scheduleHide(after: .seconds(2))
        }
    }

    private func hide(animated: Bool) {
        hideTask?.cancel()
        hideTask = nil
        autoHides = false
        fadeGeneration += 1
        guard let panel, panel.isVisible else { return }

        guard animated else {
            panel.orderOut(nil)
            model.phase = .recording
            return
        }
        let generation = fadeGeneration
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.fadeGeneration == generation else { return }
                panel.orderOut(nil)
                // Ready for the next dictation, so the first frame shown is already right.
                self.model.phase = .recording
            }
        }
    }

    /// Someone scrolling or copying the text is reading it: leaving is theirs
    /// to decide, with the close button or the next dictation.
    private func holdUntilDismissed() {
        guard autoHides else { return }
        autoHides = false
        hideTask?.cancel()
        hideTask = nil
    }

    // MARK: - Panel

    private func panelCreatedIfNeeded() -> FloatingIndicatorPanel {
        if let panel { return panel }

        let hostingView = NSHostingView(rootView: FloatingIndicatorView(
            model: model,
            coordinator: coordinator,
            audioCapture: audioCapture,
            onHover: { [weak self] in self?.pointerHovered($0) },
            onEngage: { [weak self] in self?.holdUntilDismissed() },
            onDismiss: { [weak self] in self?.hide(animated: true) }
        ))
        // The window keeps its size; the pill moves inside it.
        hostingView.sizingOptions = []

        let panel = FloatingIndicatorPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentView = hostingView
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        // NSPanel hides itself when the app deactivates, which happens as soon
        // as the settings window loses focus.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Left out of screen sharing and recordings: it is a control for the
        // person dictating, not part of what they are showing.
        panel.sharingType = .none
        panel.delegate = self

        self.panel = panel
        return panel
    }

    private func place(_ panel: NSPanel) {
        isPlacingPanel = true
        defer { isPlacingPanel = false }

        if let x = settings.floatingIndicatorPositionX, let y = settings.floatingIndicatorPositionY {
            let saved = NSRect(origin: NSPoint(x: x, y: y), size: Self.panelSize)
            // The display it was dragged to may be gone.
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(saved) }) {
                panel.setFrameOrigin(saved.origin)
                return
            }
        }

        // The screen holding the keyboard focus — where the text is about to land.
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - Self.panelSize.width / 2,
            y: visible.minY + Self.bottomMargin
        ))
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isPlacingPanel, let panel else { return }
        settings.floatingIndicatorPositionX = panel.frame.origin.x
        settings.floatingIndicatorPositionY = panel.frame.origin.y
    }
}
