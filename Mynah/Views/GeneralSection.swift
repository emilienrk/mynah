// GeneralSection.swift
// Mynah
//
// Settings tab: general UX preferences.

import SwiftUI

struct GeneralSection: View {
    @Bindable var settings: AppSettings
    let hotkeyManager: HotkeyManager

    /// Read once on appear rather than on every redraw: the Sounds directories
    /// only change when the user drops a file in one.
    @State private var availableSounds: [String] = []

    var body: some View {
        Form {
            Section("Raccourci clavier") {
                LabeledContent("Touche active") {
                    HotKeyRecorder(
                        hotKey: Binding(
                            get: { settings.currentHotKey },
                            set: { newKey in
                                settings.hotKeyCode = newKey.keyCode
                                settings.hotKeyModifiers = newKey.modifiers
                                hotkeyManager.updateHotKey(newKey)
                            }
                        ),
                        hotkeyManager: hotkeyManager
                    )
                }
            }

            Section("Mode d'enregistrement") {
                Picker("Mode d'enregistrement", selection: Binding(
                    get: { settings.hotKeyMode },
                    set: { mode in
                        settings.hotKeyMode = mode
                        hotkeyManager.setMode(mode)
                    }
                )) {
                    ForEach(HotKeyMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(settings.hotKeyMode == .pushToTalk
                     ? "Maintenez la touche — relâchez pour transcrire"
                     : "Un appui pour démarrer, un appui pour arrêter")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Comportement") {
                SettingsToggleRow(
                    label: "Coller automatiquement",
                    description: "Insère le texte directement dans l'app active après la transcription.",
                    isOn: $settings.autoPasteEnabled
                )

                SettingsToggleRow(
                    label: "Sons de dictée",
                    description: "Émet un son bref au démarrage de l'enregistrement et quand la transcription est prête.",
                    isOn: $settings.confirmationSoundEnabled
                )

                if settings.confirmationSoundEnabled {
                    SoundPickerRow(
                        label: "Au démarrage",
                        selection: $settings.startSoundName,
                        names: availableSounds
                    )
                    SoundPickerRow(
                        label: "Transcription prête",
                        selection: $settings.finishSoundName,
                        names: availableSounds
                    )
                }

                SettingsToggleRow(
                    label: "Mettre la musique en pause",
                    description: "Coupe la lecture en cours pendant la dictée, puis la relance.",
                    isOn: $settings.pauseMediaWhileRecording
                )
            }

            Section("Système") {
                SettingsToggleRow(
                    label: "Démarrer au login",
                    description: "Lance Mynah automatiquement au démarrage de macOS.",
                    isOn: $settings.launchAtLogin
                )
            }

            Section {
                Picker("Langue de l'application", selection: $settings.uiLanguage) {
                    Text(verbatim: "Français").tag("fr")
                    Text(verbatim: "English").tag("en")
                }
            } header: {
                Text("Interface")
            } footer: {
                Text("Le changement de langue nécessite le redémarrage de l'application.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            availableSounds = SystemSoundLibrary.availableNames
            settings.refreshLaunchAtLogin()
        }
    }
}

// MARK: - Sound picker row

/// Picks one of the alert sounds macOS offers. Choosing one plays it, the way
/// the system's own alert-sound list previews each entry as you click it.
private struct SoundPickerRow: View {
    let label: LocalizedStringKey
    @Binding var selection: String
    let names: [String]

    /// A sound the user has since deleted would otherwise leave the menu blank,
    /// hiding which one is actually configured.
    private var options: [String] {
        names.contains(selection) ? names : [selection] + names
    }

    var body: some View {
        Picker(label, selection: $selection) {
            ForEach(options, id: \.self) { Text($0).tag($0) }
        }
        .onChange(of: selection) { _, name in SystemSoundLibrary.play(named: name) }
    }
}

// MARK: - HotKey Recorder

struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey
    let hotkeyManager: HotkeyManager
    @State private var isRecording = false
    @State private var localMonitor: Any?
    @State private var globalMonitor: Any?
    @State private var flagsMonitor: Any?

    var body: some View {
        Button(action: toggleRecording) {
            HStack(spacing: 6) {
                if isRecording {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                    Text("Appuyez sur une touche…")
                } else {
                    Text(hotKey.displayString)
                        .fontWeight(.medium)
                    Image(systemName: "pencil")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(.bordered)
        .onDisappear { stopRecording() }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        isRecording = true
        NSApp.activate()

        // Primary path: capture via HotkeyManager's CGEventTap.
        // Only source that sees special keys (Dictation, Mission Control)
        // and consumes them before macOS reacts.
        if hotkeyManager.beginHotKeyCapture({ captured in
            if let captured { hotKey = captured }
            isRecording = false
        }) {
            return
        }

        // Fallback without accessibility permission: NSEvent monitors
        // (cannot see special keys like Dictation).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            captureKey(keyCode: Int(event.keyCode), nsFlags: event.modifierFlags)
            return nil
        }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            DispatchQueue.main.async {
                guard self.isRecording else { return }
                if event.keyCode == 53 {
                    self.stopRecording()
                    return
                }
                self.captureKey(keyCode: Int(event.keyCode), nsFlags: event.modifierFlags)
            }
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            let kc = Int(event.keyCode)
            let modifierOnlyCodes: Set<Int> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]
            guard modifierOnlyCodes.contains(kc) else { return event }

            let flags = event.modifierFlags
            let isKeyDown: Bool
            switch kc {
            case 58, 61: isKeyDown = flags.contains(.option)
            case 54, 55: isKeyDown = flags.contains(.command)
            case 56, 60: isKeyDown = flags.contains(.shift)
            case 57:     isKeyDown = flags.contains(.capsLock)
            case 59, 62: isKeyDown = flags.contains(.control)
            case 63:     isKeyDown = flags.contains(.function)
            default:     isKeyDown = false
            }

            if !isKeyDown {
                guard self.isRecording else { return event }
                hotKey = HotKey(keyCode: kc, modifiers: 0)
                stopRecording()
            }
            return event
        }
    }

    private func captureKey(keyCode: Int, nsFlags: NSEvent.ModifierFlags) {
        let relevantNS: NSEvent.ModifierFlags = [.control, .option, .shift, .command]
        let maskedNS = nsFlags.intersection(relevantNS)
        var cgRaw: UInt64 = 0
        if maskedNS.contains(.control) { cgRaw |= CGEventFlags.maskControl.rawValue }
        if maskedNS.contains(.option)  { cgRaw |= CGEventFlags.maskAlternate.rawValue }
        if maskedNS.contains(.shift)   { cgRaw |= CGEventFlags.maskShift.rawValue }
        if maskedNS.contains(.command) { cgRaw |= CGEventFlags.maskCommand.rawValue }
        hotKey = HotKey(keyCode: keyCode, modifiers: Int(cgRaw))
        stopRecording()
    }

    private func stopRecording() {
        isRecording = false
        hotkeyManager.cancelHotKeyCapture()
        if let m = localMonitor  { NSEvent.removeMonitor(m); localMonitor = nil }
        if let m = globalMonitor { NSEvent.removeMonitor(m); globalMonitor = nil }
        if let m = flagsMonitor  { NSEvent.removeMonitor(m); flagsMonitor = nil }
    }
}
