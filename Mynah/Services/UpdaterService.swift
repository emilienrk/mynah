// UpdaterService.swift
// Mynah
//
// Sparkle wrapper: starts updater on launch, exposes manual check
// and check status to the UI.

import Foundation
import Combine
import Observation
import Sparkle

@MainActor
@Observable
final class UpdaterService: NSObject, SPUUpdaterDelegate {

    enum CheckResult: Equatable {
        case none
        case checking
        case upToDate
        case available(version: String)
    }

    static let shared = UpdaterService()

    private(set) var result: CheckResult = .none
    private(set) var canCheckForUpdates = true
    private(set) var lastCheckDate: Date?

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    private var controller: SPUStandardUpdaterController!
    private var cancellable: AnyCancellable?

    private var updater: SPUUpdater { controller.updater }

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        lastCheckDate = updater.lastUpdateCheckDate
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in
                Task { @MainActor in self?.canCheckForUpdates = canCheck }
            }
        // A check brings the alert already on screen to the front.
        NotificationService.shared.onShowUpdateRequested = { [weak self] in
            self?.checkForUpdates()
        }
    }

    /// Forces initialization to begin scheduled update checks.
    func start() {}

    func checkForUpdates() {
        // With an update already on screen, Sparkle only brings it to the front
        // and reports nothing back: the spinner would never stop.
        if !updater.sessionInProgress { result = .checking }
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        result = .upToDate
        lastCheckDate = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        result = .available(version: item.displayVersionString)
        lastCheckDate = updater.lastUpdateCheckDate
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        result = .none
    }
}

// MARK: - SPUStandardUserDriverDelegate

/// A menu bar app is never the active app when a scheduled check finds an
/// update, so Sparkle opens its alert behind whatever the user is working in,
/// where it goes unseen. A notification points to it.
extension UpdaterService: @preconcurrency SPUStandardUserDriverDelegate {

    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        Task { await NotificationService.shared.sendUpdateAvailable(version: version) }
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        NotificationService.shared.removeUpdateNotification()
    }

    func standardUserDriverWillFinishUpdateSession() {
        NotificationService.shared.removeUpdateNotification()
    }
}
