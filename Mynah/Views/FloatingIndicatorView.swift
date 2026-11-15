// FloatingIndicatorView.swift
// Mynah
//
// The pill shown at the bottom of the screen during a dictation: a live
// waveform with the elapsed time while recording, a travelling wave while
// transcribing, then where the text went — or the text itself, when there
// was nowhere to paste it.

import SwiftUI

struct FloatingIndicatorView: View {
    let model: FloatingIndicatorModel
    let coordinator: RecordingCoordinator
    let audioCapture: AudioCaptureService
    let onHover: (Bool) -> Void
    /// The user is working with what is shown — scrolling it, copying it.
    let onEngage: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    private var isCard: Bool {
        if case .copied = model.phase { return true }
        return false
    }

    var body: some View {
        content
            .padding(.horizontal, isCard ? 0 : 6)
            .frame(minHeight: 40)
            // Same shape at two radii, so the pill morphs into the card.
            .background { PillBackground(cornerRadius: isCard ? 16 : 20) }
            // The pause is confirmed after the pill is up: let it widen, not jump.
            .animation(.spring(duration: 0.35, bounce: 0.2), value: coordinator.mediaPlayback.pauseStatus)
            .onHover(perform: onHover)
            .gesture(WindowDragGesture())
            // The panel never becomes key, so every click is a first click.
            .allowsWindowActivationEvents()
            .help(String(localized: "Glisser pour déplacer"))
            // Dark whatever the system appearance: the pill floats over any
            // content, and white on near-black reads over all of it.
            .environment(\.colorScheme, .dark)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .recording:
            HStack(spacing: 10) {
                PillButton(systemImage: "xmark", role: .cancel, label: "Annuler la dictée") {
                    coordinator.cancelRecording()
                }
                InputMonitor(audioCapture: audioCapture, since: coordinator.recordingStartedAt)
                    .id(model.dictation)
                MediaPauseBadge(status: coordinator.mediaPlayback.pauseStatus) {
                    coordinator.hotkeyManager.openAccessibilityPreferences()
                }
                ElapsedTime(since: coordinator.recordingStartedAt)
                PillButton(systemImage: "stop.fill", role: .stop, label: "Arrêter et transcrire") {
                    coordinator.finishRecording()
                }
            }
            .transition(.blurReplace)

        case .transcribing:
            HStack(spacing: 10) {
                ProcessingWave()
                    .padding(.leading, 10)
                Text("Transcription…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                PillButton(systemImage: "xmark", role: .cancel, label: "Annuler la transcription") {
                    coordinator.cancelRecording()
                }
            }
            .transition(.blurReplace)

        case .done(let result):
            outcome(
                systemImage: "checkmark.circle.fill",
                tint: .green,
                text: doneText(for: result)
            )

        case .copied(let text):
            CopiedCard(
                text: text,
                clipboard: coordinator.clipboardService,
                onEngage: onEngage,
                onCopy: onCopy,
                onDismiss: onDismiss
            )
                .transition(.blurReplace)

        case .silent:
            outcome(
                systemImage: "waveform.slash",
                tint: .secondary,
                text: String(localized: "Aucune parole détectée")
            )

        case .cancelled:
            outcome(
                systemImage: "xmark.circle.fill",
                tint: .secondary,
                text: String(localized: "Dictée annulée")
            )

        case .error(let message):
            outcome(
                systemImage: "exclamationmark.triangle.fill",
                tint: .orange,
                text: message
            )
        }
    }

    private func outcome(systemImage: String, tint: some ShapeStyle, text: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .symbolEffect(.bounce, value: text)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 300, alignment: .leading)
                .fixedSize()
        }
        .padding(.horizontal, 10)
        .transition(.blurReplace)
    }

    private func doneText(for result: PasteResult?) -> String {
        switch result {
        case .pasted:     String(localized: "Collé")
        case .copiedOnly: String(localized: "Copié — ⌘V pour coller")
        case nil:         String(localized: "Transcrit")
        }
    }
}

// MARK: - Background

private struct PillBackground: View {
    let cornerRadius: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(Color(white: 0.09).opacity(0.94))
            .overlay {
                // Hairline lit from above, the way the system HUDs are.
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.white.opacity(0.22), .white.opacity(0.06)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.75
                )
            }
            .shadow(color: .black.opacity(0.28), radius: 12, y: 4)
    }
}

// MARK: - Copied text

private struct CopiedCard: View {
    let text: String
    let clipboard: ClipboardService
    let onEngage: () -> Void
    let onCopy: () -> Void
    let onDismiss: () -> Void

    @State private var didCopy = false
    /// Measured inside the scroll view, where it does not depend on the height offered.
    @State private var textHeight: CGFloat?
    /// Which edges have text scrolled out of sight past them.
    @State private var hiddenEdges = HiddenEdges()

    private struct HiddenEdges: Equatable {
        var top = false
        var bottom = false
    }

    private static let maxTextHeight: CGFloat = 120

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Short text sizes the card; a long one scrolls inside a capped height.
            ScrollView {
                transcript
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { textHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(textHeight ?? Self.maxTextHeight, Self.maxTextHeight))
            .onScrollGeometryChange(for: HiddenEdges.self) { geometry in
                HiddenEdges(
                    top: geometry.contentOffset.y > 1,
                    bottom: geometry.contentOffset.y + geometry.containerSize.height < geometry.contentSize.height - 1
                )
            } action: { _, edges in
                hiddenEdges = edges
            }
            // Text fades out where more of it is hidden, instead of being cut
            // off flat at the edge of the scroll area.
            .mask {
                VStack(spacing: 0) {
                    edgeFade(hiddenEdges.top, from: .top)
                    Color.black
                    edgeFade(hiddenEdges.bottom, from: .bottom)
                }
            }
            .animation(.easeOut(duration: 0.15), value: hiddenEdges)
            .onScrollPhaseChange { _, phase in
                if phase.isScrolling { onEngage() }
            }

            HStack(spacing: 8) {
                Label("Copié — ⌘V pour coller", systemImage: "doc.on.clipboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // The clipboard may have been overwritten since.
                PillButton(
                    systemImage: didCopy ? "checkmark" : "doc.on.doc",
                    role: .cancel,
                    label: "Copier à nouveau"
                ) {
                    clipboard.copyToClipboard(text)
                    didCopy = true
                    onCopy()
                }
                .contentTransition(.symbolEffect(.replace))
                PillButton(systemImage: "xmark", role: .cancel, label: "Fermer", action: onDismiss)
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 8, trailing: 8))
        .frame(width: 360)
    }

    private func edgeFade(_ isFaded: Bool, from edge: VerticalEdge) -> some View {
        LinearGradient(
            colors: [isFaded ? .clear : .black, .black],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
        .frame(height: 14)
    }

    private var transcript: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.trailing, 6)
    }
}

// MARK: - Buttons

private struct PillButton: View {
    enum Role { case cancel, stop }

    let systemImage: String
    let role: Role
    let label: LocalizedStringKey
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: role == .stop ? 9 : 10, weight: .bold))
                .foregroundStyle(role == .stop ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .background(fill, in: Circle())
                .contentShape(Circle())
                .scaleEffect(isHovered ? 1.08 : 1)
                .animation(.spring(duration: 0.2), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }

    private var fill: Color {
        switch role {
        case .cancel: .white.opacity(isHovered ? 0.2 : 0.12)
        case .stop:   .red.opacity(isHovered ? 1 : 0.88)
        }
    }
}

// MARK: - Elapsed time

private struct ElapsedTime: View {
    let since: Date?

    var body: some View {
        Group {
            if let since {
                Text(timerInterval: since...Date.distantFuture, countsDown: false)
            } else {
                Text(verbatim: "0:00")
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(minWidth: 30, alignment: .trailing)
    }
}

// MARK: - Paused media

/// Says why the music stopped and that it comes back — or, in orange, that it
/// was meant to stop and could not.
private struct MediaPauseBadge: View {
    let status: MediaPauseStatus
    let openAccessibilitySettings: () -> Void

    var body: some View {
        switch status {
        case .idle:
            EmptyView()

        case .paused:
            Image(systemName: "music.note.slash")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .help(Text("Musique en pause — reprend à la fin de la dictée"))
                .accessibilityLabel(Text("Musique en pause — reprend à la fin de la dictée"))
                .transition(.blurReplace)

        case .blocked:
            Button(action: openAccessibilitySettings) {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.orange)
                    .symbolEffect(.pulse)
                    .frame(width: 18, height: 26)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(Text("Musique non coupée : Mynah a besoin de l'autorisation Accessibilité. Cliquez pour ouvrir les Réglages."))
            .accessibilityLabel(Text("Musique non coupée : Mynah a besoin de l'autorisation Accessibilité. Cliquez pour ouvrir les Réglages."))
            .transition(.blurReplace)
        }
    }
}

// MARK: - Input check

/// The waveform, or a warning in its place when nothing has come in from the
/// mic after a few seconds — before the user talks on into a dead input.
private struct InputMonitor: View {
    let audioCapture: AudioCaptureService
    let since: Date?

    private static let grace: TimeInterval = 3

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            if isInputDead(at: context.date) {
                HStack(spacing: 6) {
                    Image(systemName: "mic.slash.fill")
                        .foregroundStyle(.orange)
                        .symbolEffect(.pulse)
                    Text("Aucun son capté")
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 12, weight: .medium))
                .frame(width: WaveformBars.width, height: WaveformBars.height)
                .help(Text("Vérifiez le micro sélectionné dans Réglages Système › Son."))
            } else {
                LiveWaveform(audioCapture: audioCapture)
            }
        }
    }

    private func isInputDead(at date: Date) -> Bool {
        guard let since, date.timeIntervalSince(since) > Self.grace else { return false }
        return !audioCapture.hasHeardInput
    }
}

// MARK: - Waveforms

/// Scrolls the input levels from right to left, redrawn at display rate.
/// Polled only while the pill is on screen, so a hidden indicator costs nothing.
private struct LiveWaveform: View {
    let audioCapture: AudioCaptureService

    @State private var playback = WaveformPlayback(barCount: WaveformBars.barCount)

    var body: some View {
        TimelineView(.animation) { context in
            let frame = playback.advance(
                to: context.date.timeIntervalSinceReferenceDate,
                adding: audioCapture.drainLevels()
            )
            WaveformBars(heights: frame.levels.map { CGFloat($0) }, scrollOffset: CGFloat(frame.offset))
        }
        .accessibilityHidden(true)
    }
}

/// A slow wave travelling through the bars — busy, but calm.
private struct ProcessingWave: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let barCount = 9

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            WaveformBars(
                heights: (0..<barCount).map { index in
                    let phase = time * 5 - Double(index) * 0.55
                    return CGFloat(0.15 + 0.35 * (sin(phase) + 1) / 2)
                },
                fadesOldest: false
            )
        }
        .accessibilityHidden(true)
    }
}

/// Vertical capsules centred on a line, heights in 0…1.
private struct WaveformBars: View {
    static let barCount = 28

    let heights: [CGFloat]
    /// When set, the bars are slid left by this fraction of a bar, and the
    /// last one — only partly in view — is clipped at the right edge.
    var scrollOffset: CGFloat?
    /// Fades the left edge, where the oldest levels scroll out.
    var fadesOldest = true

    private static let barWidth: CGFloat = 2.5
    private static let spacing: CGFloat = 2
    private let minHeight: CGFloat = 3
    private let maxHeight: CGFloat = height

    static let height: CGFloat = 22
    /// Width of the live waveform, for what stands in its place.
    static let width = CGFloat(barCount) * (barWidth + spacing) - spacing

    private var barWidth: CGFloat { Self.barWidth }
    private var spacing: CGFloat { Self.spacing }

    private var visibleCount: Int {
        scrollOffset == nil ? heights.count : heights.count - 1
    }

    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(heights.indices, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.92))
                    .frame(width: barWidth, height: minHeight + heights[index] * (maxHeight - minHeight))
            }
        }
        .offset(x: -(scrollOffset ?? 0) * (barWidth + spacing))
        .frame(width: CGFloat(visibleCount) * (barWidth + spacing) - spacing, height: maxHeight, alignment: .leading)
        .clipped()
        .mask {
            if fadesOldest {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                Color.black
            }
        }
    }
}
