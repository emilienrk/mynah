// EngineSection.swift
// Mynah
//
// Settings tab: advanced Whisper engine parameters.

import SwiftUI

struct EngineSection: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section("Stratégie de décodage") {
                Picker("Stratégie de décodage", selection: $settings.useBeamSearch) {
                    Text("Greedy (rapide)").tag(false)
                    Text("Beam Search (précis)").tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()

                Text(settings.useBeamSearch
                     ? "Explore plusieurs chemins. Meilleur pour les noms propres, termes techniques et langues mixtes."
                     : "Choisit toujours le token le plus probable. Optimal pour la dictée en temps réel.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if settings.useBeamSearch {
                    Stepper(value: $settings.beamSize, in: 2...8) {
                        LabeledContent("Taille du beam") {
                            Text(verbatim: "\(settings.beamSize)")
                                .monospacedDigit()
                        }
                    }
                }
            }

            Section {
                TextEditor(text: $settings.initialPrompt)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .frame(height: 70)
                    .overlay(alignment: .topLeading) {
                        if settings.initialPrompt.isEmpty {
                            Text(Self.promptPlaceholder)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 5)
                                .allowsHitTesting(false)
                        }
                    }
            } header: {
                HStack {
                    Text("Vocabulaire & style")
                    Spacer()
                    Menu {
                        ForEach(PromptPreset.all) { preset in
                            Button {
                                append(preset)
                            } label: {
                                Text(preset.title)
                                Text(preset.subtitle)
                            }
                        }
                        if !settings.initialPrompt.isEmpty {
                            Divider()
                            Button("Vider le champ", role: .destructive) {
                                settings.initialPrompt = ""
                            }
                        }
                    } label: {
                        Label("Exemples", systemImage: "sparkles")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
            } footer: {
                HStack(alignment: .top, spacing: 8) {
                    Text("Whisper n'obéit pas à des consignes : il imite ce qu'il lit ici. Écrivez donc des exemples, pas des ordres — les noms propres et le jargon à reconnaître, et une phrase ponctuée comme vous souhaitez la sortie. Vide = désactivé.")
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)

                    if !settings.initialPrompt.isEmpty {
                        Text(verbatim: "\(settings.initialPrompt.count) / ≈\(PromptPreset.approximateCharacterBudget)")
                            .monospacedDigit()
                            .foregroundStyle(isPromptOverBudget ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .help("Au-delà, whisper.cpp coupe le début du texte.")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Section("Filtrage du silence") {
                VADToggleRow(settings: settings)
            }

            Section("Matériel") {
                SettingsToggleRow(
                    label: "Accélération GPU (Metal)",
                    description: "Utilise le GPU Apple Silicon pour accélérer la transcription. Désactiver libère le GPU pour d'autres apps.",
                    isOn: $settings.useGPU
                )

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Délai de déchargement") {
                        Text(verbatim: Self.formatDelay(settings.modelUnloadDelay))
                            .monospacedDigit()
                    }
                    Slider(value: $settings.modelUnloadDelay, in: 0.0...300.0) {
                        Text("Délai de déchargement")
                    } minimumValueLabel: {
                        Text(verbatim: "0s")
                    } maximumValueLabel: {
                        Text("5 min")
                    }
                    .labelsHidden()
                    Text("Temps avant de décharger le modèle de la RAM après une dictée. 0s = immédiat.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                LabeledContent("Version") {
                    Text(verbatim: String(cString: whisper_version()))
                        .monospaced()
                        .textSelection(.enabled)
                }
                LabeledContent {
                    Text(verbatim: EngineBuildInfo.whisperCommit)
                        .monospaced()
                        .textSelection(.enabled)
                } label: {
                    Text(verbatim: "Commit")
                }
            } header: {
                Text("Moteur whisper.cpp")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Le moteur est intégré à l'app : il se met à jour avec les mises à jour de Mynah.")
                    Text("Certains changements prennent effet au prochain enregistrement.")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private static func formatDelay(_ value: Double) -> String {
        let seconds = Int(value)
        if seconds == 0 { return "0s" }
        if seconds < 60 { return "\(seconds)s" }
        return seconds % 60 > 0 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 60)m"
    }

    private var isPromptOverBudget: Bool {
        settings.initialPrompt.count > PromptPreset.approximateCharacterBudget
    }

    /// Presets are additive: the prompt is just concatenated context, so combining a
    /// vocabulary preset with a style one is valid — and appending never eats what the
    /// user already typed.
    private func append(_ preset: PromptPreset) {
        let current = settings.initialPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(localized: preset.text)
        settings.initialPrompt = current.isEmpty ? text : current + "\n" + text
    }

    /// Shows the intended usage by example, since the field steers by imitation.
    private static let promptPlaceholder: LocalizedStringKey =
        "Kubernetes, PostgreSQL, Figma, Slack. Voici une phrase ponctuée normalement, avec des virgules et un point final."
}

// MARK: - VAD toggle row (with Silero model download)

/// Shared with the onboarding engine step, which offers the same toggle.
struct VADToggleRow: View {
    @Bindable var settings: AppSettings

    var body: some View {
        let model = WhisperModelDescriptor.vadSilero
        let state = ModelManager.shared.state(for: model)

        VStack(alignment: .leading, spacing: 8) {
            SettingsToggleRow(
                label: "Filtre VAD (Silero)",
                description: "Ignore les passages sans parole avant la transcription. Réduit les hallucinations sur les silences.",
                isOn: Binding(
                    get: { settings.vadEnabled },
                    set: { enabled in
                        settings.vadEnabled = enabled
                        if enabled && !ModelManager.shared.isInstalled(model) {
                            ModelManager.shared.download(model)
                        }
                    }
                )
            )

            if settings.vadEnabled {
                switch state {
                case .downloading(let progress):
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(maxWidth: 160)
                        Text("Téléchargement du modèle VAD… \(Int(progress * 100)) %")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                case .installing:
                    Text("Installation…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                case .failed(let message):
                    Text("Échec du téléchargement : \(message)")
                        .font(.subheadline)
                        .foregroundStyle(.red)
                case .idle:
                    Text("Modèle VAD manquant — désactivez puis réactivez pour relancer le téléchargement.")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                case .done:
                    EmptyView()
                }
            }
        }
    }
}
