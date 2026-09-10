// EngineConfigTests.swift
// MynahTests

import Testing
import Foundation

@MainActor
struct EngineConfigTests {

    @Test("initialPrompt is persisted and flows into the engine config")
    func initialPromptMapping() {
        let s = AppSettings.shared
        let saved = s.initialPrompt
        defer { s.initialPrompt = saved }

        s.initialPrompt = "Mynah, xcodegen, ggml"

        #expect(s.engineConfig.initialPrompt == "Mynah, xcodegen, ggml")
        #expect(UserDefaults.standard.string(forKey: "initialPrompt") == "Mynah, xcodegen, ggml")
    }

    @Test("engine config mirrors the existing engine settings")
    func existingSettingsMapping() {
        let s = AppSettings.shared
        let savedBeam = s.useBeamSearch
        let savedSize = s.beamSize
        defer {
            s.useBeamSearch = savedBeam
            s.beamSize = savedSize
        }

        s.useBeamSearch = true
        s.beamSize = 4

        let config = s.engineConfig
        #expect(config.useBeamSearch == true)
        #expect(config.beamSize == 4)
    }

    @Test("beam size stays in a range where beam search is actually beam search")
    func beamSizeClamped() {
        let s = AppSettings.shared
        let saved = s.beamSize
        defer { s.beamSize = saved }

        // 1 would decode exactly like greedy, contradicting the selected mode.
        s.beamSize = 1
        #expect(s.beamSize == 2)

        s.beamSize = 99
        #expect(s.beamSize == 8)
    }

    @Test("VAD disabled produces nil model path")
    func vadDisabledNilPath() {
        let s = AppSettings.shared
        let saved = s.vadEnabled
        defer { s.vadEnabled = saved }

        s.vadEnabled = false

        #expect(s.engineConfig.vadEnabled == false)
        #expect(s.engineConfig.vadModelPath == nil)
    }

    @Test("VAD enabled resolves the path only when the model file exists")
    func vadEnabledPathResolution() {
        let s = AppSettings.shared
        let saved = s.vadEnabled
        defer { s.vadEnabled = saved }

        s.vadEnabled = true
        let model = WhisperModelDescriptor.vadSilero

        if model.isDownloaded {
            #expect(s.engineConfig.vadModelPath == model.localURL.path(percentEncoded: false))
        } else {
            #expect(s.engineConfig.vadModelPath == nil)
        }
    }

    @Test("pauseMediaWhileRecording round-trips through UserDefaults")
    func pauseMediaWhileRecordingPersists() {
        let s = AppSettings.shared
        let saved = s.pauseMediaWhileRecording
        defer { s.pauseMediaWhileRecording = saved }

        s.pauseMediaWhileRecording = false
        #expect(s.pauseMediaWhileRecording == false)
        #expect(UserDefaults.standard.bool(forKey: "pauseMediaWhileRecording") == false)

        s.pauseMediaWhileRecording = true
        #expect(s.pauseMediaWhileRecording == true)
        #expect(UserDefaults.standard.bool(forKey: "pauseMediaWhileRecording") == true)
    }

    @Test("a non-empty prompt is carried to every decode window")
    func promptIsCarried() {
        let prompt = strdup("Mynah, xcodegen, ggml")
        defer { free(prompt) }

        var config = WhisperEngineConfig.default
        config.initialPrompt = "Mynah, xcodegen, ggml"

        let params = WhisperService.makeParams(
            config: config,
            maxThreads: 4,
            strategy: WHISPER_SAMPLING_GREEDY,
            cLanguage: nil,
            cPrompt: UnsafePointer(prompt),
            cVadPath: nil
        )

        #expect(params.initial_prompt != nil)
        #expect(params.carry_initial_prompt == true)
    }

    @Test("each preset stands alone within the prompt budget")
    func presetsFitTheBudget() {
        #expect(PromptPreset.all.isEmpty == false)

        for preset in PromptPreset.all {
            let text = String(localized: preset.text)
            #expect(text.isEmpty == false)
            #expect(text.count <= PromptPreset.approximateCharacterBudget)
        }

        let titles = Set(PromptPreset.all.map(\.id))
        #expect(titles.count == PromptPreset.all.count)
    }

    @Test("an empty prompt leaves carry_initial_prompt off")
    func emptyPromptIsNotCarried() {
        let params = WhisperService.makeParams(
            config: .default,
            maxThreads: 4,
            strategy: WHISPER_SAMPLING_GREEDY,
            cLanguage: nil,
            cPrompt: nil,
            cVadPath: nil
        )

        #expect(params.initial_prompt == nil)
        #expect(params.carry_initial_prompt == false)
    }

    @Test("hasCompletedOnboarding round-trips through UserDefaults")
    func onboardingFlagPersists() {
        let s = AppSettings.shared
        let saved = s.hasCompletedOnboarding
        defer { s.hasCompletedOnboarding = saved }

        s.hasCompletedOnboarding = true
        #expect(s.hasCompletedOnboarding == true)
        #expect(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") == true)

        s.hasCompletedOnboarding = false
        #expect(s.hasCompletedOnboarding == false)
        #expect(UserDefaults.standard.bool(forKey: "hasCompletedOnboarding") == false)
    }

    @Test("onboardingStepRaw round-trips through UserDefaults and resets on completion")
    func onboardingStepRawPersists() {
        let s = AppSettings.shared
        let savedStep = s.onboardingStepRaw
        let savedCompleted = s.hasCompletedOnboarding
        defer {
            s.onboardingStepRaw = savedStep
            s.hasCompletedOnboarding = savedCompleted
        }

        s.onboardingStepRaw = 2
        #expect(s.onboardingStepRaw == 2)
        #expect(UserDefaults.standard.integer(forKey: "onboardingStep") == 2)

        s.hasCompletedOnboarding = true
        #expect(s.onboardingStepRaw == 0)
        #expect(UserDefaults.standard.object(forKey: "onboardingStep") == nil)
    }

    @Test("uiLanguage normalizes to fr or en and persists to AppleLanguages")
    func uiLanguageNormalizes() {
        let s = AppSettings.shared
        let saved = s.uiLanguage
        defer { s.uiLanguage = saved }

        s.uiLanguage = "en-US"
        #expect(s.uiLanguage == "en")
        #expect(UserDefaults.standard.stringArray(forKey: "AppleLanguages") == ["en"])

        s.uiLanguage = "fr-FR"
        #expect(s.uiLanguage == "fr")
        #expect(UserDefaults.standard.stringArray(forKey: "AppleLanguages") == ["fr"])
    }
}
