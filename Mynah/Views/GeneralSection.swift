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

                if settings.autoPasteEnabled && !settings.alwaysPasteBundleIDs.isEmpty {
                    AlwaysPasteAppsRow(settings: settings)
                }

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

                // The media key is dropped without a word: say it here rather
                // than let the switch look like it works.
                if settings.pauseMediaWhileRecording && !hotkeyManager.hasAccessibilityPermission {
                    HStack {
                        Label {
                            Text("Sans l'autorisation Accessibilité, Mynah ne peut pas mettre la musique en pause.")
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        Spacer()
                        Button("Ouvrir les Réglages") {
                            hotkeyManager.openAccessibilityPreferences()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            Section("Indicateur à l'écran") {
                SettingsToggleRow(
                    label: "Afficher l'indicateur flottant",
                    description: "Affiche en bas de l'écran une capsule avec l'onde sonore, le temps écoulé et des boutons pour arrêter ou annuler.",
                    isOn: $settings.showFloatingIndicator
                )

                if settings.showFloatingIndicator {
                    SettingsToggleRow(
                        label: "Afficher le texte s'il n'a pas pu être collé",
                        description: "Quand aucun champ de texte n'est actif, ou que le collage automatique est coupé, l'indicateur montre le texte copié.",
                        isOn: $settings.showTranscriptWhenNotPasted
                    )

                    if settings.floatingIndicatorPositionX != nil {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Position personnalisée")
                                Text("L'indicateur a été déplacé à la main.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Réinitialiser") {
                                settings.floatingIndicatorPositionX = nil
                                settings.floatingIndicatorPositionY = nil
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section("Système") {
                SettingsToggleRow(
                    label: "Démarrer au login",
                    description: "Lance Mynah automatiquement au démarrage de macOS.",
                    isOn: $settings.launchAtLogin
                )
            }

            Section {
                Picker("Apparence", selection: $settings.appearance) {
                    Text("Automatique").tag(AppAppearance.system)
                    Text("Clair").tag(AppAppearance.light)
                    Text("Sombre").tag(AppAppearance.dark)
                }

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

// MARK: - Always-paste apps

/// The apps added from the floating indicator, where Mynah pastes without
/// seeing a field. Stored by bundle identifier; name and icon are looked up.
private struct AlwaysPasteAppsRow: View {
    @Bindable var settings: AppSettings

    private struct App: Identifiable {
        let id: String
        let name: String
        let icon: NSImage?
    }

    /// An app since uninstalled still shows, by its identifier, so it can be removed.
    private var apps: [App] {
        settings.alwaysPasteBundleIDs.map { bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                return App(id: bundleID, name: bundleID, icon: nil)
            }
            return App(
                id: bundleID,
                name: url.deletingPathExtension().lastPathComponent,
                icon: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
            )
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Toujours coller dans ces apps")
                Text("Mynah y colle même sans voir de champ de texte, et laisse le texte dans le presse-papier au cas où.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(apps) { app in
                HStack(spacing: 8) {
                    Group {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable()
                        } else {
                            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 18, height: 18)
                    Text(verbatim: app.name)
                    Spacer()
                    Button("Retirer") {
                        settings.alwaysPasteBundleIDs.remove(app.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
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
