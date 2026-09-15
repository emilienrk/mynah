// SettingsComponents.swift
// Mynah
//
// Shared reusable UI components for the Settings window.

import SwiftUI

// MARK: - Glassmorphism card

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.white.opacity(0.075), Color.white.opacity(0.04)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)
            )
            .containerShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let icon: String
    // LocalizedStringKey, not String: Text(String) skips the string catalog.
    let title: LocalizedStringKey

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.28), lineWidth: 1)
                )

            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white.opacity(0.75))
                .textCase(.uppercase)
                .kerning(0.6)
        }
    }
}
