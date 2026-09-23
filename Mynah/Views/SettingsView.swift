// SettingsView.swift
// Mynah
//
// Native macOS Settings window using an NSToolbar (via SettingsWindowController).
// Each tab maps to an existing section view — no content changes needed.

import SwiftUI

// MARK: - NativeSettingsView

/// Root view embedded in the Settings scene. Uses the standard macOS tab toolbar.
struct NativeSettingsView: View {
    @EnvironmentObject private var services: ServicesContainer
    @ObservedObject var tabSelection: SettingsWindowController.TabSelection

    var body: some View {
        Group {
            switch tabSelection.currentTab {
            case .general:
                GeneralSection(
                    settings: services.settings,
                    hotkeyManager: services.hotkeyManager
                )
            case .model:
                ModelSection(
                    settings: services.settings,
                    coordinator: services.coordinator
                )
            case .language:
                LanguageSection(settings: services.settings)
            case .engine:
                EngineSection(settings: services.settings)
            case .permissions:
                PermissionsSection(micManager: services.micPermManager)
            case .history:
                HistoryView(historyService: services.historyService)
            case .about:
                AboutSection()
            }
        }
        // Force the window to stay at a consistent size across tabs
        .frame(width: 560, height: 520)
    }
}

// MARK: - Tab enum

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, model, language, engine, permissions, history, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "Général")
        case .model: return String(localized: "Modèle")
        case .language: return String(localized: "Langue")
        case .engine: return String(localized: "Moteur")
        case .permissions: return String(localized: "Permissions")
        case .history: return String(localized: "Historique")
        case .about: return String(localized: "À propos")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        case .model: return "cube.box.fill"
        case .language: return "globe"
        case .engine: return "cpu.fill"
        case .permissions: return "lock.shield.fill"
        case .history: return "clock.fill"
        case .about: return "info.circle.fill"
        }
    }
}
