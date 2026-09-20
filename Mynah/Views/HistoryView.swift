// HistoryView.swift
// Mynah
//
// Displays the transcription history.

import SwiftUI

struct HistoryView: View {
    @Bindable var historyService: HistoryService

    @State private var confirmsClear = false
    @State private var copiedItemId: UUID?
    @State private var deletingItemIds: Set<UUID> = []
    
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
                        let isDeleting = deletingItemIds.contains(item.id)
                        SettingsCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top) {
                                    Text(dateFormatter.string(from: item.date))
                                        .font(.system(size: 11))
                                        .foregroundStyle(.white.opacity(0.4))
                                    
                                    Spacer()
                                    
                                    HStack(spacing: 6) {
                                        HistoryCopyButton(
                                            isCopied: copiedItemId == item.id,
                                            action: { copyToClipboard(item: item) }
                                        )

                                        HistoryDeleteButton(
                                            action: { deleteItem(id: item.id) }
                                        )
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
                        .opacity(isDeleting ? 0 : 1)
                        .scaleEffect(isDeleting ? 0.95 : 1)
                        .offset(x: isDeleting ? 12 : 0)
                    }
                }
            }
        }
    }
    
    private func copyToClipboard(item: HistoryItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.text, forType: .string)

        withAnimation(.spring(duration: 0.2)) {
            copiedItemId = item.id
        }

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedItemId == item.id {
                withAnimation(.easeInOut(duration: 0.2)) {
                    copiedItemId = nil
                }
            }
        }
    }

    private func deleteItem(id: UUID) {
        withAnimation(.easeInOut(duration: 0.18)) {
            _ = deletingItemIds.insert(id)
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                historyService.deleteItem(id: id)
                deletingItemIds.remove(id)
            }
        }
    }
}

// MARK: - Action Buttons

private struct HistoryCopyButton: View {
    let isCopied: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 11, weight: isCopied ? .semibold : .medium))
                .foregroundStyle(isCopied ? Color.green : (isHovered ? .white.opacity(0.9) : .white.opacity(0.45)))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isCopied ? Color.green.opacity(0.15) : (isHovered ? Color.white.opacity(0.08) : Color.clear))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(isCopied ? String(localized: "Copié !") : String(localized: "Copier le texte"))
        .accessibilityLabel(isCopied ? String(localized: "Copié !") : String(localized: "Copier le texte"))
    }
}

private struct HistoryDeleteButton: View {
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isHovered ? Color.red : .white.opacity(0.4))
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovered ? Color.red.opacity(0.15) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(String(localized: "Supprimer cette transcription"))
        .accessibilityLabel(String(localized: "Supprimer cette transcription"))
    }
}
