// CaptureStallDetectorTests.swift
// MynahTests

import Testing

struct CaptureStallDetectorTests {

    @Test("A growing sample count is never a stall, silence included")
    func growingCountIsHealthy() {
        var detector = CaptureStallDetector()
        for count in stride(from: 0, through: 64_000, by: 16_000) {
            let stalled = detector.isStalled(sampleCount: count, engineRunning: true)
            #expect(!stalled)
        }
    }

    @Test("A stopped engine is a stall straight away")
    func stoppedEngineIsStalled() {
        var detector = CaptureStallDetector()
        let stalled = detector.isStalled(sampleCount: 0, engineRunning: false)
        #expect(stalled)
    }

    @Test("A frozen count is tolerated for the configured number of checks")
    func frozenCountEventuallyStalls() {
        var detector = CaptureStallDetector()
        // The second reading is the first idle one: a Bluetooth headset may still be negotiating.
        let readings = (0..<3).map { _ in detector.isStalled(sampleCount: 8_000, engineRunning: true) }
        #expect(readings == [false, false, true])
    }

    @Test("New samples clear the idle streak")
    func growthResetsStreak() {
        var detector = CaptureStallDetector()
        let readings = [0, 0, 4_000, 4_000].map { detector.isStalled(sampleCount: $0, engineRunning: true) }
        #expect(readings == [false, false, false, false])
    }

    @Test("Reset forgets the last count, so a restarted engine gets a fresh window")
    func resetStartsOver() {
        var detector = CaptureStallDetector()
        _ = detector.isStalled(sampleCount: 8_000, engineRunning: true)
        _ = detector.isStalled(sampleCount: 8_000, engineRunning: true)
        detector.reset()
        let readings = (0..<2).map { _ in detector.isStalled(sampleCount: 8_000, engineRunning: true) }
        #expect(readings == [false, false])
    }
}
