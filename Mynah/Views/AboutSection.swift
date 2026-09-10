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
        VStack(alignment: .leading, spacing: 12) {
            identityCard
            updatesCard
            privacyCard
            licensesCard
        }
        .sheet(isPresented: $showsLicenses) {
            LicenseSheet(text: Self.licenseText)
        }
    }

    // MARK: - Identity

    private var identityCard: some View {
        SettingsCard {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Mynah")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                    Text(Self.versionLabel)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                }

                Spacer()
            }
        }
    }

    // MARK: - Updates

    private var updatesCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeader(icon: "arrow.down.circle.fill", title: "Mises à jour")

                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(updateStatusLabel)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                        Text(lastCheckLabel)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.35))
                    }

                    Spacer()

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
                        .frame(minWidth: 120)
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .disabled(!updater.canCheckForUpdates)
                }

                Divider().opacity(0.08)

                SettingsToggleRow(
                    icon: "clock.arrow.circlepath",
                    label: "Vérifier automatiquement",
                    description: "Mynah cherche une nouvelle version en arrière-plan. Les mises à jour incluent le moteur whisper.cpp intégré.",
                    isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    )
                )
            }
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

    private var privacyCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "lock.shield.fill", title: "Confidentialité")

                Text("Votre voix est transcrite sur votre Mac. Aucun audio, aucune transcription et aucune donnée d'usage ne quittent l'appareil.")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Mynah n'établit que deux connexions sortantes :")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.35))
                    bullet("le téléchargement des modèles, depuis Hugging Face")
                    bullet("la vérification des mises à jour de l'application")
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(verbatim: "•")
            Text(text)
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.35))
    }

    // MARK: - Licenses

    private var licensesCard: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(icon: "doc.text.fill", title: "Logiciels tiers")

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

                Button {
                    showsLicenses = true
                } label: {
                    Text("Afficher les licences complètes")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.white.opacity(0.75))
                .padding(.top, 2)
            }
        }
    }

    private func componentRow(name: String, license: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
            Text(license)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.3))
            Spacer()
            if let destination = URL(string: url) {
                Link(destination: destination) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.white.opacity(0.4))
            }
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
                    .foregroundStyle(.white.opacity(0.7))
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
        .preferredColorScheme(.dark)
    }
}
