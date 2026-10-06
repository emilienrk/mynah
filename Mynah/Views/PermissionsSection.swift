// PermissionsSection.swift
// Mynah
//
// Settings tab: microphone + accessibility permission status and guided actions.

import SwiftUI
import AppKit
import AVFoundation

// MARK: - PermissionsSection

struct PermissionsSection: View {
    @Bindable var micManager: MicrophonePermissionManager

    @State private var isAXTrusted: Bool = AXIsProcessTrusted()

    var body: some View {
        Form {
            micSection
            accessibilitySection
        }
        .formStyle(.grouped)
        // A grant made in System Settings notifies no one: poll until nothing is
        // missing. The window is kept when closed, so the tab may never disappear.
        .task {
            refreshAXStatus()
            micManager.refresh()
            while !Task.isCancelled, !isAXTrusted || !micManager.canRecord {
                try? await Task.sleep(for: .seconds(1))
                refreshAXStatus()
                micManager.refresh()
            }
        }
    }

    // MARK: - Microphone

    private var micSection: some View {
        Section {
            LabeledContent {
                micActionButton
            } label: {
                statusLabel(micStatusLabel, color: micStatusColor)
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Mynah a besoin du microphone pour capturer votre voix et la transcrire localement.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var micActionButton: some View {
        switch micManager.status {
        case .undetermined:
            permissionButton(label: "Demander l'accès", icon: "hand.raised") {
                Task { await micManager.requestIfNeeded() }
            }
        case .denied, .restricted:
            permissionButton(label: "Ouvrir les Réglages", icon: "arrow.up.right.square") {
                micManager.openSystemPreferences()
            }
        case .granted:
            EmptyView()
        }
    }

    private var micStatusColor: Color {
        switch micManager.status {
        case .granted:      return .green
        case .undetermined: return .orange
        case .denied:       return .red
        case .restricted:   return .red
        }
    }

    private var micStatusLabel: LocalizedStringKey {
        switch micManager.status {
        case .granted:      return "Accès accordé"
        case .undetermined: return "Non déterminé"
        case .denied:       return "Accès refusé"
        case .restricted:   return "Accès restreint"
        }
    }

    // MARK: - Accessibility

    private var accessibilitySection: some View {
        Section {
            LabeledContent {
                if !isAXTrusted {
                    permissionButton(label: "Ouvrir les Réglages", icon: "arrow.up.right.square") {
                        openAXPreferences()
                    }
                }
            } label: {
                statusLabel(isAXTrusted ? "Accès accordé" : "Non accordé", color: isAXTrusted ? .green : .orange)
            }
        } header: {
            Text("Accessibilité")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Requise pour simuler Cmd+V et coller le texte transcrit dans l'application active.\nDans Réglages → Confidentialité & Sécurité → Accessibilité, activez Mynah.")
                if !isAXTrusted {
                    // macOS ties the grant to one exact build: after an update
                    // the switch stays on but no longer applies to this copy.
                    Text("Mynah est déjà coché ? Retirez-le de la liste avec −, puis ajoutez-le à nouveau.")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func statusLabel(_ text: LocalizedStringKey, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
        }
    }

    // MARK: - Helpers

    private func refreshAXStatus() {
        isAXTrusted = AXIsProcessTrusted()
    }

    private func openAXPreferences() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func permissionButton(label: LocalizedStringKey, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: icon)
        }
    }
}
