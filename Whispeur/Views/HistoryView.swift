// HistoryView.swift
// Whispeur
//
// Displays the transcription history.

import SwiftUI

struct HistoryView: View {
    @Bindable var historyService: HistoryService

    @State private var confirmsClear = false
    
    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            
            // Header
            SettingsCard {
                HStack {
                    SectionHeader(icon: "clock.fill", title: "Historique des transcriptions")
                    
                    Spacer()
                    
                    Button(role: .destructive) {
                        confirmsClear = true
                    } label: {
                        Label(LocalizedStringKey("Effacer"), systemImage: "trash")
                    }
                    .disabled(historyService.items.isEmpty)
                    .confirmationDialog(
                        Text("Effacer tout l'historique ?"),
                        isPresented: $confirmsClear,
                        titleVisibility: .visible
                    ) {
                        Button("Effacer", role: .destructive) { historyService.clearAll() }
                        Button("Annuler", role: .cancel) { }
                    } message: {
                        Text("Les \(historyService.items.count) transcriptions conservées seront supprimées.")
                    }
                }
            }
            
            // Content
            if historyService.items.isEmpty {
                SettingsCard {
                    VStack(spacing: 12) {
                        Image(systemName: "clock")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.2))
                        Text("Aucune transcription récente.")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                }
            } else {
                VStack(spacing: 12) {
                    ForEach(historyService.items) { item in
                        SettingsCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(dateFormatter.string(from: item.date))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                    
                                    Spacer()
                                    
                                    HStack(spacing: 8) {
                                        Button {
                                            copyToClipboard(item.text)
                                        } label: {
                                            Image(systemName: "doc.on.doc")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.white.opacity(0.5))
                                        }
                                        .buttonStyle(.borderless)
                                        .help(String(localized: "Copier le texte"))

                                        Button {
                                            withAnimation(.easeInOut(duration: 0.2)) {
                                                historyService.deleteItem(id: item.id)
                                            }
                                        } label: {
                                            Image(systemName: "xmark")
                                                .font(.system(size: 10, weight: .semibold))
                                                .foregroundStyle(.white.opacity(0.4))
                                        }
                                        .buttonStyle(.borderless)
                                        .help(String(localized: "Supprimer cette transcription"))
                                    }
                                }
                                
                                TextField("", text: Binding(
                                    get: { item.text },
                                    set: { historyService.updateItem(id: item.id, newText: $0) }
                                ), axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
