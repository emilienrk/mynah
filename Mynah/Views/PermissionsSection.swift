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

    /// Refreshes AX trust status on appear and on button tap.
    @State private var isAXTrusted: Bool = false

    var body: some View {
        Form {
            micSection
            accessibilitySection
        }
        .formStyle(.grouped)
        .onAppear { refreshAXStatus() }
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
                        // Refresh after a short delay (user may grant while settings are open)
                        Task {
                            try? await Task.sleep(for: .seconds(2))
                            refreshAXStatus()
                        }
                    }
                }
            } label: {
                statusLabel(isAXTrusted ? "Accès accordé" : "Non accordé", color: isAXTrusted ? .green : .orange)
            }
        } header: {
            Text("Accessibilité")
        } footer: {
            Text("Requise pour simuler Cmd+V et coller le texte transcrit dans l'application active.\nDans Réglages → Confidentialité & Sécurité → Accessibilité, activez Mynah.")
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
