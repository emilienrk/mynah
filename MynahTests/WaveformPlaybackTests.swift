// WaveformPlaybackTests.swift
// MynahTests

import Testing

struct WaveformPlaybackTests {

    /// Feeds levels the way the tap does — five at once every 100 ms — while
    /// frames are drawn at 120 Hz. Returns the offset reached at each frame,
    /// counted in bars from the start.
    private func play(seconds: Double) -> (positions: [Double], playback: WaveformPlayback) {
        let playback = WaveformPlayback(barCount: 28)
        let frameInterval = 1.0 / 120
        var positions: [Double] = []
        var shifted = 0
        var lastLevels: [Float] = []
        var nextLevel: Float = 0

        for frame in 0..<Int(seconds * 120) {
            let time = Double(frame) * frameInterval
            var fresh: [Float] = []
            if frame % 12 == 0 {
                fresh = (0..<5).map { _ in nextLevel += 0.001; return nextLevel }
            }
            let result = playback.advance(to: time, adding: fresh)
            if !lastLevels.isEmpty, result.levels != lastLevels { shifted += 1 }
            lastLevels = result.levels
            positions.append(Double(shifted) + result.offset)
        }
        return (positions, playback)
    }

    @Test("Scrolls at a steady pace despite levels arriving in bursts")
    func steadyPace() {
        let positions = play(seconds: 4).positions
        // Past the first second, once the pace has settled.
        let steps = zip(positions.dropFirst(120), positions.dropFirst(121)).map { $1 - $0 }
        let expected = WaveformPlayback.barsPerSecond / 120

        #expect(steps.allSatisfy { $0 >= 0 })
        #expect(steps.allSatisfy { abs($0 - expected) < expected * 0.5 })
    }

    @Test("The backlog stays bounded, so the wave does not lag further behind")
    func boundedLatency() {
        let playback = play(seconds: 10).playback
        #expect(playback.backlog <= Int(WaveformPlayback.targetBacklog) * 2)
    }

    @Test("A bar keeps the loudest of its levels")
    func barKeepsPeak() {
        let playback = WaveformPlayback(barCount: 4)
        _ = playback.advance(to: 0, adding: [0.1, 0.9, 0.2, 0.3])
        #expect(playback.backlog == 1)

        var frame = playback.advance(to: 0, adding: [])
        for step in 1...30 {
            frame = playback.advance(to: Double(step) / 60, adding: [])
        }
        #expect(frame.levels.last == 0.9)
    }

    @Test("Holds still when no level comes in")
    func holdsWhenStarved() {
        let playback = WaveformPlayback(barCount: 4)
        _ = playback.advance(to: 0, adding: [0.5, 0.5, 0.5])
        let first = playback.advance(to: 0.05, adding: [])
        var last = first
        for frame in 1...60 {
            last = playback.advance(to: 0.05 + Double(frame) / 120, adding: [])
        }
        #expect(last.levels == first.levels || last.levels.last == 0.5)
        #expect(last.offset < 1)
    }
}
