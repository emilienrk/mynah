// SettingsComponents.swift
// Mynah
//
// Shared reusable UI components for the Settings window.

import SwiftUI

// MARK: - Toggle row

/// Title and explanation on the left, switch on the right — the System Settings
/// row. Laid out by hand rather than left to Form, so the onboarding cards can
/// host it outside a Form and still get the same layout.
struct SettingsToggleRow: View {
    // LocalizedStringKey, not String: Text(String) skips the string catalog.
    let label: LocalizedStringKey
    let description: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(description)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Toggle(isOn: $isOn) { Text(label) }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}
