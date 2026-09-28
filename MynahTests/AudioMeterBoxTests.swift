// AudioMeterBoxTests.swift
// MynahTests

import Testing

struct AudioMeterBoxTests {

    @Test("drain hands back levels in order, then nothing")
    func drainReturnsAppendedLevelsOnce() {
        let box = AudioMeterBox()
        box.append([0.1, 0.2])
        box.append([0.3])

        #expect(box.drain() == [0.1, 0.2, 0.3])
        #expect(box.drain().isEmpty)
    }

    /// Nothing drains the box while the indicator is hidden; it must not grow
    /// for the length of the dictation.
    @Test("Keeps only the most recent levels when no one drains")
    func boundedWhenNotDrained() {
        let box = AudioMeterBox()
        let levels = (0..<(AudioMeterBox.capacity + 10)).map { Float($0) }
        box.append(levels)

        let drained = box.drain()
        #expect(drained.count == AudioMeterBox.capacity)
        #expect(drained.last == levels.last)
    }

    @Test("Silence maps to 0, full scale to 1")
    func levelBounds() {
        #expect(AudioMeterBox.level(rms: 0) == 0)
        #expect(AudioMeterBox.level(rms: 1) == 1)
    }

    /// On a linear scale, normal speech (~-25 dBFS, RMS ≈ 0.056) barely moves
    /// the bars; the dB mapping must put it well within the visible range.
    @Test("Speech-level RMS lands mid-range")
    func speechIsVisible() {
        let speech = AudioMeterBox.level(rms: 0.056)
        #expect(speech > 0.5 && speech < 0.8)
    }

    @Test("A dead input is told apart from a quiet room")
    func detectsDeadInput() {
        let box = AudioMeterBox()
        box.record([Float](repeating: 0, count: 1_600))
        #expect(!box.hasHeardInput)

        // Around -60 dBFS: room noise on a working mic, too quiet to move the bars.
        box.record([Float](repeating: 0.001, count: 320))
        #expect(box.hasHeardInput)
        #expect(AudioMeterBox.level(rms: 0.001) == 0)

        box.reset()
        #expect(!box.hasHeardInput)
    }

    @Test("One level per 20 ms window, the last one partial")
    func levelsPerWindow() {
        let samples = [Float](repeating: 0.5, count: AudioMeterBox.windowSize * 2 + 10)
        let levels = AudioMeterBox.levels(of: samples)

        #expect(levels.count == 3)
        #expect(levels.allSatisfy { abs($0 - AudioMeterBox.level(rms: 0.5)) < 0.0001 })
    }
}
