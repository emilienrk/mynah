// WaveformPlayback.swift
// Mynah
//
// Paces the input levels shown by the floating indicator's waveform.

import Foundation

/// Plays levels out at a steady pace. They arrive a tap buffer at a time —
/// about five every 100 ms — and shown as they come, the wave would jump by
/// five bars at once, then stand still.
///
/// A bar stands for three 20 ms levels, keeping the loudest: one bar per
/// level scrolled past too fast to follow, and the peak keeps syllables apart
/// where an average would smooth them over.
final class WaveformPlayback {
    struct Frame {
        /// One more than the bars shown: the next one slides in from the right.
        let levels: [Float]
        /// How far, in bars, the wave has slid left towards the next level.
        let offset: Double
    }

    static let levelsPerBar = 3
    /// Levels come one per 20 ms window.
    static let barsPerSecond = 50.0 / Double(levelsPerBar)
    /// Enough in hand to ride over the gap between two tap buffers.
    static let targetBacklog = 3.0

    private var levels: [Float]
    private var queue: [Float] = []
    /// Levels still short of a full bar.
    private var partialBar: [Float] = []
    private var offset = 0.0
    private var pace = 1.0
    private var lastTime: TimeInterval?

    init(barCount: Int) {
        levels = Array(repeating: 0, count: barCount + 1)
    }

    var backlog: Int { queue.count }

    func advance(to time: TimeInterval, adding fresh: [Float]) -> Frame {
        partialBar.append(contentsOf: fresh)
        while partialBar.count >= Self.levelsPerBar {
            queue.append(partialBar.prefix(Self.levelsPerBar).max() ?? 0)
            partialBar.removeFirst(Self.levelsPerBar)
        }
        // Capped, so a frame skipped while the panel was off screen is not
        // caught up in one leap.
        let elapsed = lastTime.map { min(max(time - $0, 0), 0.1) } ?? 0
        lastTime = time

        // Faster when the backlog grows, slower when it runs low, eased over
        // half a second so the speed does not pulse with every buffer.
        let wantedPace = min(2, Double(queue.count) / Self.targetBacklog)
        pace += (wantedPace - pace) * min(1, elapsed / 0.5)

        offset += elapsed * Self.barsPerSecond * pace
        while offset >= 1 {
            guard !queue.isEmpty else {
                // Nothing left to show: hold on the last level rather than invent one.
                offset = 0
                break
            }
            levels.removeFirst()
            levels.append(queue.removeFirst())
            offset -= 1
        }
        return Frame(levels: levels, offset: offset)
    }
}
