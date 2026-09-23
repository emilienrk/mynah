// ModelSection.swift
// Mynah
//
// Settings tab: model selection + download with progress bar.

import SwiftUI

struct ModelSection: View {
    @Bindable var settings: AppSettings
    let coordinator: RecordingCoordinator

    @State private var manager = ModelManager.shared
    @State private var expandedFamilies: Set<String> = []

    private let families = WhisperModelDescriptor.families
    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        Form {
            Section {
                ForEach(families) { family in
                    FamilyGroup(
                        family: family,
                        isExpanded: Binding(
                            get: { expandedFamilies.contains(family.name) },
                            set: { setExpanded(family.name, $0) }
                        ),
                        states: family.variants.map { manager.state(for: $0) },
                        selectedFilename: settings.selectedModelFilename,
                        row: { variant in row(for: variant) }
                    )
                }
            } header: {
                Text("Modèle Whisper")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Label {
                        Text("Marquez jusqu'à \(AppSettings.maxFavorites) modèles en favori pour un accès rapide depuis la barre de menu.")
                    } icon: {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    }
                    Text("Stockés dans ~/Library/Application Support/Mynah/Models/")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            manager.refreshInstalled()
            expandFamiliesInUse()
        }
    }

    // MARK: - Row construction

    private func row(for model: WhisperModelDescriptor) -> ModelRow {
        ModelRow(
            model: model,
            downloadState: manager.state(for: model),
            isSelected: settings.selectedModelFilename == model.filename,
            isHeavy: model.isHeavy(forPhysicalMemory: physicalMemory),
            isFavorite: settings.isFavorite(filename: model.filename),
            canFavorite: settings.favoritedModelFilenames.count < AppSettings.maxFavorites
                      || settings.isFavorite(filename: model.filename),
            onSelect: {
                settings.selectedModelFilename = model.filename
                coordinator.modelURL = model.localURL
            },
            onToggleFavorite: {
                settings.toggleFavorite(filename: model.filename)
            },
            onDownload: { manager.download(model) },
            onCancel:   { manager.cancel(model) },
            onDelete:   {
                if settings.selectedModelFilename == model.filename {
                    settings.selectedModelFilename = ""
                    coordinator.modelURL = nil
                }
                // Also remove from favorites if deleted
                if settings.isFavorite(filename: model.filename) {
                    settings.toggleFavorite(filename: model.filename)
                }
                manager.delete(model)
            }
        )
    }

    // MARK: - Expansion

    private func setExpanded(_ family: String, _ expanded: Bool) {
        if expanded {
            expandedFamilies.insert(family)
        } else {
            expandedFamilies.remove(family)
        }
    }

    /// Opens the families the user already has something in, so what's installed
    /// is visible without hunting through collapsed rows.
    private func expandFamiliesInUse() {
        expandedFamilies = Set(
            families
                .filter { $0.variants.contains { manager.isInstalled($0) } }
                .map(\.name)
        )
    }
}

// MARK: - Family group

private struct FamilyGroup<Row: View>: View {
    let family: WhisperModelFamily
    @Binding var isExpanded: Bool
    let states: [ModelDownloadState]
    let selectedFilename: String
    @ViewBuilder let row: (WhisperModelDescriptor) -> Row

    private var installedCount: Int {
        states.filter { $0 == .done }.count
    }

    private var activeVariant: WhisperModelDescriptor? {
        family.variants.first { $0.filename == selectedFilename }
    }

    private var isBusy: Bool {
        states.contains {
            if case .downloading = $0 { return true }
            if case .installing = $0 { return true }
            return false
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            ForEach(family.variants) { variant in
                row(variant)
            }
        } label: {
            HStack {
                Text(family.name)
                    .foregroundStyle(installedCount > 0 ? .primary : .secondary)
                Spacer()
                summary
            }
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let active = activeVariant {
            HStack(spacing: 6) {
                Text(active.quantization)
                    .foregroundStyle(.secondary)
                Text("Actif")
                    .fontWeight(.medium)
                    .foregroundStyle(Color.accentColor)
            }
        } else if isBusy {
            ProgressView().controlSize(.small)
        } else if installedCount > 0 {
            if installedCount > 1 {
                Text("\(installedCount) installés")
                    .foregroundStyle(.secondary)
            } else {
                Text("1 installé")
                    .foregroundStyle(.secondary)
            }
        } else {
            if family.variants.count > 1 {
                Text("\(family.variants.count) variantes")
                    .foregroundStyle(.tertiary)
            } else {
                Text("1 variante")
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Model row

private struct ModelRow: View {
    let model: WhisperModelDescriptor
    let downloadState: ModelDownloadState
    let isSelected: Bool
    let isHeavy: Bool
    let isFavorite: Bool
    let canFavorite: Bool
    let onSelect:        () -> Void
    let onToggleFavorite: () -> Void
    let onDownload:      () -> Void
    let onCancel:        () -> Void
    let onDelete:        () -> Void

    /// `.done` is the single source of truth: ModelManager derives it from its
    /// observable on-disk index, so the row reacts to install and delete alike.
    private var isDownloaded: Bool { downloadState == .done }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                selectionIndicator

                // Precision + size — the family header already carries the name
                HStack(spacing: 6) {
                    Text(model.quantization)
                        .monospaced()
                        .foregroundStyle(isDownloaded ? .primary : .secondary)
                    if model.isEnglishOnly {
                        Text(verbatim: "EN")
                            .font(.caption2.bold())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.quaternary))
                    }
                    Text(model.fileSize)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if isDownloaded {
                    Button(action: onToggleFavorite) {
                        Image(systemName: isFavorite ? "star.fill" : "star")
                            .foregroundStyle(isFavorite ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                    }
                    .buttonStyle(.borderless)
                    .help(isFavorite ? "Retirer des favoris" : canFavorite ? "Ajouter aux favoris" : "Maximum \(AppSettings.maxFavorites) favoris")
                    .disabled(!canFavorite && !isFavorite)
                    .animation(.spring(duration: 0.25), value: isFavorite)
                }

                trailingAction
            }

            if isHeavy {
                Label {
                    Text("Lourd pour ce Mac (\(Int(ProcessInfo.processInfo.physicalMemory >> 30)) Go de RAM) : risque de ralentissements.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill")
                }
                .font(.subheadline)
                .foregroundStyle(.orange)
            }

            if case .downloading(let progress) = downloadState {
                ProgressView(value: progress)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: downloadState)
        .contentShape(Rectangle())
        .onTapGesture { if isDownloaded { onSelect() } }
    }

    // MARK: - Sub-views

    private var selectionIndicator: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .opacity(isDownloaded ? 1 : 0.4)
    }

    @ViewBuilder
    private var trailingAction: some View {
        switch downloadState {
        case .idle:
            Button(action: onDownload) {
                Label(LocalizedStringKey("Télécharger"), systemImage: "arrow.down.circle")
            }

        case .downloading(let progress):
            // Cancel button + percentage
            HStack(spacing: 8) {
                Text(verbatim: "\(Int(progress * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button(role: .cancel, action: onCancel) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Annuler")
            }

        case .installing:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Installation…")
                    .foregroundStyle(.secondary)
            }

        case .done:
            HStack(spacing: 8) {
                Text(isSelected ? "Actif" : "Installé")
                    .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Supprimer le modèle")
            }

        case .failed:
            Button(action: onDownload) {
                Label(LocalizedStringKey("Réessayer"), systemImage: "arrow.clockwise")
            }
        }
    }
}
