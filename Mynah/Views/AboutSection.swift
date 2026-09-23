// AboutSection.swift
// Mynah
//
// Settings tab: version, privacy statement and third-party license notices.
// Reproducing the MIT notices of the bundled components is a license obligation.

import SwiftUI
import AppKit

// MARK: - AboutSection

struct AboutSection: View {
    @State private var showsLicenses = false

    private var updater: UpdaterService { .shared }

    var body: some View {
        Form {
            identitySection
            updatesSection
            privacySection
            licensesSection
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showsLicenses) {
            LicenseSheet(text: Self.licenseText)
        }
    }

    // MARK: - Identity

    private var identitySection: some View {
        Section {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: "Mynah")
                        .font(.title3.weight(.semibold))
                    Text(Self.versionLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Updates

    private var updatesSection: some View {
        Section("Mises à jour") {
            LabeledContent {
                Button {
                    updater.checkForUpdates()
                } label: {
                    HStack(spacing: 6) {
                        if updater.result == .checking {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text("Vérifier maintenant")
                    }
                }
                .disabled(!updater.canCheckForUpdates)
            } label: {
                Text(updateStatusLabel)
                Text(lastCheckLabel)
            }

            SettingsToggleRow(
                label: "Vérifier automatiquement",
                description: "Mynah cherche une nouvelle version en arrière-plan. Les mises à jour incluent le moteur whisper.cpp intégré.",
                isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                )
            )
        }
    }

    private var updateStatusLabel: String {
        switch updater.result {
        case .checking:
            return String(localized: "Recherche d'une mise à jour…")
        case .upToDate:
            return String(localized: "Mynah est à jour")
        case .available(let version):
            return String(localized: "Version \(version) disponible")
        case .none:
            return String(localized: "Version \(Self.shortVersion) installée")
        }
    }

    private var lastCheckLabel: String {
        guard let date = updater.lastCheckDate else {
            return String(localized: "Aucune vérification depuis l'installation.")
        }
        let formatted = date.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "Dernière vérification : \(formatted)")
    }

    // MARK: - Privacy

    private var privacySection: some View {
        Section("Confidentialité") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Votre voix est transcrite sur votre Mac. Aucun audio, aucune transcription et aucune donnée d'usage ne quittent l'appareil.")
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mynah n'établit que deux connexions sortantes :")
                    bullet("le téléchargement des modèles, depuis Hugging Face")
                    bullet("la vérification des mises à jour de l'application")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func bullet(_ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "•")
            Text(text)
        }
    }

    // MARK: - Licenses

    private var licensesSection: some View {
        Section("Logiciels tiers") {
            componentRow(
                name: "whisper.cpp / ggml",
                license: "MIT",
                url: "https://github.com/ggml-org/whisper.cpp"
            )
            componentRow(
                name: "Sparkle",
                license: "MIT",
                url: "https://github.com/sparkle-project/Sparkle"
            )
            componentRow(
                name: "Modèles Whisper",
                license: "MIT · OpenAI",
                url: "https://github.com/openai/whisper"
            )
            componentRow(
                name: "Silero VAD",
                license: "MIT",
                url: "https://github.com/snakers4/silero-vad"
            )

            Button("Afficher les licences complètes") {
                showsLicenses = true
            }
        }
    }

    private func componentRow(name: String, license: String, url: String) -> some View {
        LabeledContent {
            if let destination = URL(string: url) {
                Link(destination: destination) {
                    Image(systemName: "arrow.up.right.square")
                }
            }
        } label: {
            Text(name)
            Text(license)
        }
    }

    // MARK: - Content

    private static var shortVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private static var versionLabel: String {
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "Version \(shortVersion) (\(build))"
    }

    private static var licenseText: String {
        guard
            let url = Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return String(localized: "Fichier de licences introuvable.")
        }
        return text
    }
}

// MARK: - License sheet

private struct LicenseSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                Text(text)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }

            Divider()

            HStack {
                Spacer()
                Button("Fermer") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 560, height: 480)
    }
}
