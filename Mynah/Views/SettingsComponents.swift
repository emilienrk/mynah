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
    var icon: String? = nil
    let title: LocalizedStringKey

    init(icon: String? = nil, title: LocalizedStringKey) {
        self.icon = icon
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.45))
            .textCase(.uppercase)
            .kerning(0.6)
    }
}
