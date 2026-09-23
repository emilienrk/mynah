// LanguageSection.swift
// Mynah
//
// Settings tab: transcription language picker.

import SwiftUI

struct LanguageSection: View {
    @Bindable var settings: AppSettings

    @State private var searchQuery: String = ""

    private var filteredLanguages: [WhisperLanguage] {
        if searchQuery.isEmpty { return WhisperLanguage.all }
        let q = searchQuery.lowercased()
        return WhisperLanguage.all.filter {
            $0.displayName.lowercased().contains(q) ||
            ($0.whisperCode ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Langue active") {
                    Text(verbatim: settings.selectedLanguage.displayName)
                }
            } header: {
                Text("Langue de transcription")
            } footer: {
                if settings.languageCode == "auto" {
                    Label {
                        Text("Whisper détecte automatiquement la langue parlée.")
                    } icon: {
                        Image(systemName: "sparkles")
                            .foregroundStyle(.yellow)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }
            }

            Section {
                TextField(text: $searchQuery, prompt: Text("Rechercher une langue…")) {
                    Text("Rechercher une langue…")
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()

                ForEach(filteredLanguages) { lang in
                    LanguageRow(
                        language: lang,
                        isSelected: settings.languageCode == lang.id,
                        onSelect: { settings.selectedLanguage = lang }
                    )
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Language row

private struct LanguageRow: View {
    let language: WhisperLanguage
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 16)
                    .opacity(isSelected ? 1 : 0)

                Text(verbatim: language.displayName)
                    .foregroundStyle(.primary)

                Spacer()

                if let code = language.whisperCode {
                    Text(code.uppercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                } else {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.yellow)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
