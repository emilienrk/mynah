import SwiftUI
import AppKit

@MainActor
final class SettingsWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?
    private var tabSelection = TabSelection()

    var isVisible: Bool {
        window?.isVisible == true
    }

    class TabSelection: ObservableObject {
        @Published var currentTab: SettingsTab = .general
    }

    func show(services: ServicesContainer, tab: SettingsTab = .general) {
        guard services.settings.hasCompletedOnboarding else {
            OnboardingWindowController.shared.show(services: services)
            return
        }

        setupMainMenuIfNeeded()
        NSApp.setActivationPolicy(.regular)

        tabSelection.currentTab = tab

        if let existingWindow = window {
            if let toolbar = existingWindow.toolbar {
                toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
            }
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = NativeSettingsView(tabSelection: tabSelection)
            .environmentObject(services)

        let hostingController = NSHostingController(rootView: settingsView)
        
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        newWindow.title = String(localized: "Paramètres")
        newWindow.minSize = NSSize(width: 560, height: 520)
        if !newWindow.setFrameAutosaveName("WhispeurSettingsWindow") {
            newWindow.center()
        }
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.contentViewController = hostingController

        // Setup NSToolbar
        let toolbar = NSToolbar(identifier: "SettingsToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
        newWindow.toolbar = toolbar
        newWindow.toolbarStyle = .preference
        
        self.window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard let tab = SettingsTab(rawValue: itemIdentifier.rawValue) else { return nil }
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.label = tab.title
        item.image = NSImage(systemSymbolName: tab.systemImage, accessibilityDescription: tab.title)
        item.target = self
        item.action = #selector(tabChanged(_:))
        return item
    }

    @objc private func tabChanged(_ sender: NSToolbarItem) {
        if let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue) {
            tabSelection.currentTab = tab
        }
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        if !OnboardingWindowController.shared.isVisible {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Main Menu

    /// Configures standard menus when active so text shortcuts (⌘C, ⌘V, ⌘A) and ⌘W work predictably.
    private func setupMainMenuIfNeeded() {
        let mainMenu = NSApp.mainMenu ?? NSMenu()

        let hasEditMenu = mainMenu.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSText.copy(_:)) } == true }
        if !hasEditMenu {
            let editMenuItem = NSMenuItem()
            let editMenu = NSMenu(title: String(localized: "Édition"))
            editMenu.addItem(withTitle: String(localized: "Annuler"), action: Selector(("undo:")), keyEquivalent: "z")
            let redoItem = NSMenuItem(title: String(localized: "Rétablir"), action: Selector(("redo:")), keyEquivalent: "Z")
            editMenu.addItem(redoItem)
            editMenu.addItem(NSMenuItem.separator())
            editMenu.addItem(withTitle: String(localized: "Couper"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
            editMenu.addItem(withTitle: String(localized: "Copier"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
            editMenu.addItem(withTitle: String(localized: "Coller"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
            editMenu.addItem(withTitle: String(localized: "Tout sélectionner"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
            editMenuItem.submenu = editMenu
            mainMenu.addItem(editMenuItem)
        }

        let hasWindowMenu = mainMenu.items.contains { $0.submenu?.items.contains { $0.action == #selector(NSWindow.performClose(_:)) } == true }
        if !hasWindowMenu {
            let windowMenuItem = NSMenuItem()
            let windowMenu = NSMenu(title: String(localized: "Fenêtre"))
            windowMenu.addItem(withTitle: String(localized: "Fermer"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            windowMenu.addItem(withTitle: String(localized: "Réduire"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
            windowMenuItem.submenu = windowMenu
            mainMenu.addItem(windowMenuItem)
            NSApp.windowsMenu = windowMenu
        }

        NSApp.mainMenu = mainMenu
    }
}
