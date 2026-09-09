// UpdaterService.swift
// Whispeur
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
            userDriverDelegate: nil
        )
        lastCheckDate = updater.lastUpdateCheckDate
        cancellable = updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] canCheck in
                Task { @MainActor in self?.canCheckForUpdates = canCheck }
            }
    }

    /// Forces initialization to begin scheduled update checks.
    func start() {}

    func checkForUpdates() {
        result = .checking
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
