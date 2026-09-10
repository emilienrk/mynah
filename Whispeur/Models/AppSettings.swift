// AppSettings.swift
// Whispeur
//
// Centralized persistent preferences backed by UserDefaults.
// All stored properties are in-memory so @Observable can track mutations.
// Each didSet syncs to UserDefaults for persistence.

import Foundation
import ServiceManagement

@MainActor
@Observable
final class AppSettings {

    // MARK: - Singleton

    static let shared = AppSettings()

    // MARK: - Init (load from UserDefaults)

    private init() {
        let ud = UserDefaults.standard
        // Default hotkey: Dictation key (176) — replaces Apple Dictation with Whisper.
        // Migration: earlier builds used 160 by default, which is
        // actually Mission Control (F3); dictation key is 176.
        if ud.integer(forKey: "hotKeyCode") == 160,
           ((ud.object(forKey: "hotKeyModifiers") as? Int) ?? 0) == 0 {
            ud.set(176, forKey: "hotKeyCode")
        }
        hotKeyCode             = (ud.integer(forKey: "hotKeyCode").nonZero) ?? 176
        hotKeyModifiers        = (ud.object(forKey: "hotKeyModifiers") as? Int) ?? 0
        _hotKeyModeRaw         = ud.string(forKey: "hotKeyMode") ?? HotKeyMode.pushToTalk.rawValue
        selectedModelFilename  = ud.string(forKey: "selectedModel") ?? "ggml-base.bin"
        languageCode           = ud.string(forKey: "language") ?? "auto"
        _autoPasteEnabled      = (ud.object(forKey: "autoPaste") as? Bool) ?? true
        // Not persisted: macOS owns this one. A stale UserDefaults value could
        // show the toggle on while the app was never registered (fresh install
        // over leftover preferences) or off after the user removed it from
        // System Settings > Login Items.
        _launchAtLogin         = SMAppService.mainApp.status == .enabled
        ud.removeObject(forKey: "launchAtLogin")
        _confirmationSound     = (ud.object(forKey: "confirmationSound") as? Bool) ?? false
        _startSoundName        = ud.string(forKey: "startSoundName") ?? "Tink"
        _finishSoundName       = ud.string(forKey: "finishSoundName") ?? "Pop"
        _pauseMediaWhileRecording = (ud.object(forKey: "pauseMediaWhileRecording") as? Bool) ?? true
        _useBeamSearch         = (ud.object(forKey: "useBeamSearch") as? Bool) ?? false
        _beamSize              = (ud.object(forKey: "beamSize") as? Int) ?? 5
        _useGPU                = (ud.object(forKey: "useGPU") as? Bool) ?? true
        _modelUnloadDelay      = (ud.object(forKey: "modelUnloadDelay") as? Double) ?? 0.0
        _initialPrompt         = ud.string(forKey: "initialPrompt") ?? ""
        _vadEnabled            = (ud.object(forKey: "vadEnabled") as? Bool) ?? false
        _hasCompletedOnboarding = (ud.object(forKey: "hasCompletedOnboarding") as? Bool) ?? false
        _onboardingStepRaw     = ud.integer(forKey: "onboardingStep")
        if let data = ud.data(forKey: "favoritedModels"),
           let arr  = try? JSONDecoder().decode([String].self, from: data) {
            favoritedModelFilenames = arr
        } else {
            favoritedModelFilenames = []
        }
        
        if let appleLangs = ud.stringArray(forKey: "AppleLanguages"), let first = appleLangs.first {
            _uiLanguage = first.hasPrefix("fr") ? "fr" : "en"
        } else {
            _uiLanguage = Locale.preferredLanguages.first?.hasPrefix("fr") == true ? "fr" : "en"
        }
    }

    // MARK: - Hotkey

    var hotKeyCode: Int {
        didSet { UserDefaults.standard.set(hotKeyCode, forKey: "hotKeyCode") }
    }
    var hotKeyModifiers: Int {
        didSet { UserDefaults.standard.set(hotKeyModifiers, forKey: "hotKeyModifiers") }
    }

    private var _hotKeyModeRaw: String {
        didSet { UserDefaults.standard.set(_hotKeyModeRaw, forKey: "hotKeyMode") }
    }
    var hotKeyMode: HotKeyMode {
        get { HotKeyMode(rawValue: _hotKeyModeRaw) ?? .pushToTalk }
        set { _hotKeyModeRaw = newValue.rawValue }
    }

    // MARK: - Model

    var selectedModelFilename: String {
        didSet { UserDefaults.standard.set(selectedModelFilename, forKey: "selectedModel") }
    }

    var selectedModelDescriptor: WhisperModelDescriptor? {
        WhisperModelDescriptor.catalog.first { $0.filename == selectedModelFilename }
    }

    var selectedModelURL: URL? {
        selectedModelDescriptor?.localURL
    }

    // MARK: - Language

    var languageCode: String {
        didSet { UserDefaults.standard.set(languageCode, forKey: "language") }
    }

    var selectedLanguage: WhisperLanguage {
        get { WhisperLanguage.find(byCode: languageCode) }
        set { languageCode = newValue.id }
    }

    // MARK: - General settings

    private var _uiLanguage: String {
        didSet {
            UserDefaults.standard.set([_uiLanguage], forKey: "AppleLanguages")
        }
    }
    var uiLanguage: String {
        get { _uiLanguage }
        set { _uiLanguage = newValue.hasPrefix("fr") ? "fr" : "en" }
    }

    private var _autoPasteEnabled: Bool {
        didSet { UserDefaults.standard.set(_autoPasteEnabled, forKey: "autoPaste") }
    }
    var autoPasteEnabled: Bool {
        get { _autoPasteEnabled }
        set { _autoPasteEnabled = newValue }
    }

    private var _launchAtLogin: Bool
    var launchAtLogin: Bool {
        get { _launchAtLogin }
        set {
            guard newValue != _launchAtLogin else { return }
            _launchAtLogin = applyLaunchAtLogin(newValue)
        }
    }

    /// Re-reads the system state, which the user can change from
    /// System Settings > General > Login Items behind our back.
    func refreshLaunchAtLogin() {
        _launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private var _confirmationSound: Bool {
        didSet { UserDefaults.standard.set(_confirmationSound, forKey: "confirmationSound") }
    }
    var confirmationSoundEnabled: Bool {
        get { _confirmationSound }
        set { _confirmationSound = newValue }
    }

    private var _startSoundName: String {
        didSet { UserDefaults.standard.set(_startSoundName, forKey: "startSoundName") }
    }
    /// Alert sound played when the microphone opens, by name — resolved against
    /// the system Sounds directories, never stored as a path.
    var startSoundName: String {
        get { _startSoundName }
        set { _startSoundName = newValue }
    }

    private var _finishSoundName: String {
        didSet { UserDefaults.standard.set(_finishSoundName, forKey: "finishSoundName") }
    }
    /// Alert sound played when the transcription is ready.
    var finishSoundName: String {
        get { _finishSoundName }
        set { _finishSoundName = newValue }
    }

    private var _pauseMediaWhileRecording: Bool {
        didSet { UserDefaults.standard.set(_pauseMediaWhileRecording, forKey: "pauseMediaWhileRecording") }
    }
    /// Pause whatever is playing while a dictation runs, then resume it afterwards.
    var pauseMediaWhileRecording: Bool {
        get { _pauseMediaWhileRecording }
        set { _pauseMediaWhileRecording = newValue }
    }

    private var _hasCompletedOnboarding: Bool {
        didSet { UserDefaults.standard.set(_hasCompletedOnboarding, forKey: "hasCompletedOnboarding") }
    }
    /// False until the first-launch setup has been walked through or dismissed.
    var hasCompletedOnboarding: Bool {
        get { _hasCompletedOnboarding }
        set {
            _hasCompletedOnboarding = newValue
            if newValue {
                _onboardingStepRaw = 0
                UserDefaults.standard.removeObject(forKey: "onboardingStep")
            }
        }
    }

    private var _onboardingStepRaw: Int {
        didSet { UserDefaults.standard.set(_onboardingStepRaw, forKey: "onboardingStep") }
    }
    /// Saved step index of the onboarding wizard across launches.
    var onboardingStepRaw: Int {
        get { _onboardingStepRaw }
        set { _onboardingStepRaw = newValue }
    }

    // MARK: - Engine (Whisper params)

    private var _useBeamSearch: Bool {
        didSet { UserDefaults.standard.set(_useBeamSearch, forKey: "useBeamSearch") }
    }
    /// When true, uses WHISPER_SAMPLING_BEAM_SEARCH instead of greedy.
    var useBeamSearch: Bool {
        get { _useBeamSearch }
        set { _useBeamSearch = newValue }
    }

    private var _beamSize: Int {
        didSet { UserDefaults.standard.set(_beamSize, forKey: "beamSize") }
    }
    /// Number of beams (1–10). Only used when useBeamSearch is true.
    var beamSize: Int {
        get { _beamSize }
        set { _beamSize = min(8, max(2, newValue)) }
    }

    private var _useGPU: Bool {
        didSet { UserDefaults.standard.set(_useGPU, forKey: "useGPU") }
    }
    /// Enable Metal GPU acceleration for the Whisper context.
    var useGPU: Bool {
        get { _useGPU }
        set { _useGPU = newValue }
    }

    private var _modelUnloadDelay: Double {
        didSet { UserDefaults.standard.set(_modelUnloadDelay, forKey: "modelUnloadDelay") }
    }
    /// Delay in seconds before unloading the model (0 = immediately).
    var modelUnloadDelay: Double {
        get { _modelUnloadDelay }
        set { _modelUnloadDelay = max(0, newValue) }
    }

    private var _initialPrompt: String {
        didSet { UserDefaults.standard.set(_initialPrompt, forKey: "initialPrompt") }
    }
    /// Context text fed to the decoder before each dictation (vocabulary, proper nouns, punctuation style). Empty = disabled.
    var initialPrompt: String {
        get { _initialPrompt }
        set { _initialPrompt = newValue }
    }

    private var _vadEnabled: Bool {
        didSet { UserDefaults.standard.set(_vadEnabled, forKey: "vadEnabled") }
    }
    /// Silero VAD filter: skips non-speech audio before transcription (needs the VAD model file).
    var vadEnabled: Bool {
        get { _vadEnabled }
        set { _vadEnabled = newValue }
    }

    /// Engine config snapshot passed to WhisperService for one transcription.
    /// Resolves the VAD model path here (MainActor) so the actor never touches FileManager for it.
    var engineConfig: WhisperEngineConfig {
        let vadModel = WhisperModelDescriptor.vadSilero
        return WhisperEngineConfig(
            useBeamSearch: useBeamSearch,
            beamSize: beamSize,
            useGPU: useGPU,
            initialPrompt: initialPrompt,
            vadEnabled: vadEnabled,
            vadModelPath: (vadEnabled && vadModel.isDownloaded) ? vadModel.localURL.path(percentEncoded: false) : nil
        )
    }

    // MARK: - Favorited models (max 4)

    static let maxFavorites = 4

    /// In-memory array tracked by @Observable — persisted to UserDefaults on each write.
    var favoritedModelFilenames: [String] {
        didSet {
            let data = try? JSONEncoder().encode(favoritedModelFilenames)
            UserDefaults.standard.set(data, forKey: "favoritedModels")
        }
    }

    func toggleFavorite(filename: String) {
        var current = favoritedModelFilenames
        if let idx = current.firstIndex(of: filename) {
            current.remove(at: idx)
        } else if current.count < AppSettings.maxFavorites {
            current.append(filename)
        }
        favoritedModelFilenames = current
    }

    func isFavorite(filename: String) -> Bool {
        favoritedModelFilenames.contains(filename)
    }

    var favoritedModelDescriptors: [WhisperModelDescriptor] {
        favoritedModelFilenames.compactMap { fn in
            WhisperModelDescriptor.catalog.first { $0.filename == fn }
        }
    }

    // MARK: - Derived helpers

    var currentHotKey: HotKey {
        HotKey(keyCode: hotKeyCode, modifiers: hotKeyModifiers)
    }

    // MARK: - Private helpers

    /// Returns the state actually reached, so a change macOS denies snaps the
    /// toggle back instead of claiming something that never happened.
    private func applyLaunchAtLogin(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return enabled
        } catch {
            return SMAppService.mainApp.status == .enabled
        }
    }
}

private extension Int {
    var nonZero: Int? { self != 0 ? self : nil }
}
