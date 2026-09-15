// ModelHardwareFitTests.swift
// MynahTests

import Testing

struct ModelHardwareFitTests {

    private let eightGB: UInt64 = 8 << 30
    private let sixteenGB: UInt64 = 16 << 30

    @Test("File size parses from both MiB and GiB labels")
    func fileSizeBytes() {
        #expect(WhisperModelDescriptor.named("small-q5_1").fileSizeBytes == 181 << 20)
        #expect(WhisperModelDescriptor.named("large-v3").fileSizeBytes == UInt64(2.9 * Double(1 << 30)))
        #expect(WhisperModelDescriptor.vadSilero.fileSizeBytes == 1 << 20)
    }

    @Test("Only unquantized large models are flagged on 8 GB, nothing on 16 GB")
    func heaviness() {
        let heavyOn8GB = WhisperModelDescriptor.catalog.filter { $0.isHeavy(forPhysicalMemory: eightGB) }.map(\.name)
        #expect(Set(heavyOn8GB) == ["large-v1", "large-v2", "large-v3"])
        #expect(!WhisperModelDescriptor.catalog.contains { $0.isHeavy(forPhysicalMemory: sixteenGB) })
    }

    @Test("Onboarding never offers a model too heavy for the Mac")
    func onboardingChoicesFitMemory() {
        for memory in [eightGB, sixteenGB, 32 << 30] {
            let choices = WhisperModelDescriptor.onboardingChoices(physicalMemory: memory)
            #expect(!choices.isEmpty)
            #expect(!choices.contains { $0.model.isHeavy(forPhysicalMemory: memory) })
        }
    }

    @Test("16 GB and up get unquantized weights first")
    func onboardingTiers() {
        #expect(WhisperModelDescriptor.onboardingChoices(physicalMemory: eightGB).first?.model.name == "large-v3-turbo-q5_0")
        #expect(WhisperModelDescriptor.onboardingChoices(physicalMemory: sixteenGB).first?.model.name == "large-v3-turbo")
    }
}
