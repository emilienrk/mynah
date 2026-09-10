// OnboardingWindowController.swift
// Mynah
//
// Hosts the first-launch setup in its own window. LSUIElement apps have no
// window by default, so the app has to be activated explicitly or the window
// opens behind whatever the user was doing.

import SwiftUI
import AppKit

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private var window: NSWindow?

    var isVisible: Bool {
        window?.isVisible == true
    }

    func show(services: ServicesContainer) {
        NSApp.setActivationPolicy(.regular)

        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = OnboardingView(services: services) { [weak self] in
            services.settings.hasCompletedOnboarding = true
            self?.close()
        }

        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = String(localized: "Configuration de Mynah")
        newWindow.center()
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.contentViewController = NSHostingController(rootView: view)

        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        window = nil
        if !SettingsWindowController.shared.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    private func close() {
        window?.close()
        window = nil
        if !SettingsWindowController.shared.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
