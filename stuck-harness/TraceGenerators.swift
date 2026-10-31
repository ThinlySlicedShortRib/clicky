//
//  TraceGenerators.swift
//  stuck-harness
//
//  Seeded, synthetic behaviour traces. Nothing here is a recording of a real
//  person: each scenario is a hand-written model of how someone might act.
//  This directory is outside the app target, so no trace can reach the app.
//

import Foundation

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    /// SplitMix64: small, and reproducible across runs and machines.
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58476D1CE4E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D049BB133111EB
        return mixed ^ (mixed >> 31)
    }
}

/// One synthetic session. `stuckOnsetInSeconds` is nil for a busy trace.
struct BehaviourTrace {
    let scenarioName: String
    let isStuck: Bool
    let stuckOnsetInSeconds: Double?
    let durationInSeconds: Double
    let events: [StuckBehaviourEvent]
}

/// Writes events while walking a clock forward. Delays are scaled by random
/// noise, and `timingNoise` sets how much, so held-out traces can be messier
/// than the ones the model was tuned on.
struct TraceBuilder {
    private(set) var currentTime: Double = 0
    private(set) var events: [StuckBehaviourEvent] = []
    private var generator: SeededGenerator
    private let timingNoise: Double
    private var pointerTile = (column: 4, row: 3)

    init(seed: UInt64, timingNoise: Double) {
        generator = SeededGenerator(seed: seed)
        self.timingNoise = timingNoise
    }

    mutating func uniform(_ lowerBound: Double, _ upperBound: Double) -> Double {
        Double.random(in: lowerBound...upperBound, using: &generator)
    }

    mutating func integer(_ lowerBound: Int, _ upperBound: Int) -> Int {
        Int.random(in: lowerBound...upperBound, using: &generator)
    }

    mutating func chance(_ probability: Double) -> Bool {
        uniform(0, 1) < probability
    }

    private mutating func noisy(_ seconds: Double) -> Double {
        let firstSample = uniform(Double.ulpOfOne, 1)
        let secondSample = uniform(0, 1)
        let normalSample = (-2 * log(firstSample)).squareRoot() * cos(2 * .pi * secondSample)
        return seconds * exp(normalSample * timingNoise)
    }

    private static func tileIdentifier(column: Int, row: Int) -> Int {
        column * 1_000 + row
    }

    private var currentTileIdentifier: Int {
        Self.tileIdentifier(column: pointerTile.column, row: pointerTile.row)
    }

    private mutating func emit(_ kind: StuckBehaviourEventKind) {
        events.append(StuckBehaviourEvent(timestampInSeconds: currentTime, kind: kind))
    }

    mutating func pause(_ lowerBound: Double, _ upperBound: Double) {
        let baseSeconds = uniform(lowerBound, upperBound)
        currentTime += noisy(baseSeconds)
    }

    /// Glides to a tile over about half a second, at 10 reports a second.
    mutating func moveTo(column: Int, row: Int) {
        let reportCount = Int(noisy(0.5) * 10) + 2
        let totalDistance = uniform(200, 700)
        for reportIndex in 0..<reportCount {
            if reportIndex == reportCount / 2 {
                pointerTile = (column, row)
            }
            emit(.pointerMovement(distanceInPoints: totalDistance / Double(reportCount), coarseAreaIdentifier: currentTileIdentifier))
            currentTime += 0.1
        }
        pointerTile = (column, row)
    }

    /// The mouse moving aimlessly around where it already is.
    mutating func wander(seconds: Double, tileRadius: Int) {
        let endTime = currentTime + noisy(seconds)
        let homeTile = pointerTile
        while currentTime < endTime {
            if chance(0.08) {
                pointerTile = (
                    homeTile.column + integer(-tileRadius, tileRadius),
                    homeTile.row + integer(-tileRadius, tileRadius)
                )
            }
            emit(.pointerMovement(distanceInPoints: uniform(10, 45), coarseAreaIdentifier: currentTileIdentifier))
            currentTime += 0.1
        }
        pointerTile = homeTile
    }

    mutating func click() {
        emit(.click(coarseAreaIdentifier: currentTileIdentifier))
        currentTime += 0.05
    }

    mutating func click(column: Int, row: Int) {
        moveTo(column: column, row: row)
        click()
    }

    mutating func undo() {
        emit(.undo)
        currentTime += 0.05
    }

    mutating func redo() {
        emit(.redo)
        currentTime += 0.05
    }

    mutating func cancel() {
        emit(.cancel)
        currentTime += 0.05
    }

    mutating func modeToggle() {
        emit(.modeToggle)
        currentTime += 0.05
    }

    mutating func keys(count: Int, keysPerSecond: Double) {
        for _ in 0..<count {
            emit(.anonymousKeyPress)
            currentTime += noisy(1 / keysPerSecond)
        }
    }

    /// A stroke or a gizmo pull: the pointer moves, then the button comes up.
    mutating func drag(seconds: Double) {
        wander(seconds: seconds, tileRadius: 1)
        emit(.dragFinished)
        currentTime += 0.05
    }

    mutating func scroll(ticks: Int, ticksPerSecond: Double) {
        for _ in 0..<ticks {
            emit(.scrollTick)
            currentTime += noisy(1 / ticksPerSecond)
        }
    }

    mutating func browserTrip(awaySeconds: Double, whileAway: (inout TraceBuilder) -> Void = { _ in }) {
        emit(.leftForBrowser)
        let returnTime = currentTime + noisy(awaySeconds)
        whileAway(&self)
        currentTime = max(currentTime, returnTime)
        emit(.returnedFromBrowser)
    }

    func finished(scenarioName: String, isStuck: Bool, stuckOnsetInSeconds: Double?) -> BehaviourTrace {
        BehaviourTrace(
            scenarioName: scenarioName,
            isStuck: isStuck,
            stuckOnsetInSeconds: stuckOnsetInSeconds,
            durationInSeconds: currentTime + 15,
            events: events.sorted { $0.timestampInSeconds < $1.timestampInSeconds }
        )
    }
}

struct TraceScenario {
    let name: String
    let isStuck: Bool
    /// Stuck scenarios the model isn't expected to catch, kept so recall isn't
    /// flattered by only testing obvious cases.
    let isDeliberatelyHard: Bool
    let build: (inout TraceBuilder) -> Double?

    func makeTrace(seed: UInt64, timingNoise: Double) -> BehaviourTrace {
        var builder = TraceBuilder(seed: seed, timingNoise: timingNoise)
        let stuckOnsetInSeconds = build(&builder)
        return builder.finished(scenarioName: name, isStuck: isStuck, stuckOnsetInSeconds: stuckOnsetInSeconds)
    }
}

/// Ordinary work that opens every stuck trace, so "stuck" is a change in
/// behaviour rather than the whole session.
private func normalWorkLeadIn(_ builder: inout TraceBuilder) {
    for _ in 0..<builder.integer(2, 4) {
        builder.click(column: builder.integer(0, 8), row: builder.integer(0, 5))
        builder.pause(0.8, 2.5)
        builder.keys(count: builder.integer(1, 3), keysPerSecond: 4)
        builder.pause(1, 4)
    }
}

enum TraceLibrary {
    static let stuckScenarios: [TraceScenario] = [
        TraceScenario(name: "stuck: undo loop on one object", isStuck: true, isDeliberatelyHard: false) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            for _ in 0..<builder.integer(5, 8) {
                builder.click(column: 4, row: 3)
                builder.pause(0.3, 1)
                builder.keys(count: 1, keysPerSecond: 4)
                builder.wander(seconds: builder.uniform(1.5, 4), tileRadius: 1)
                builder.click()
                builder.pause(1.5, 5)
                builder.undo()
                if builder.chance(0.25) {
                    builder.pause(0.2, 0.5)
                    builder.undo()
                }
                builder.pause(1, 3)
            }
            return onset
        },
        TraceScenario(name: "stuck: reopening a menu without choosing", isStuck: true, isDeliberatelyHard: false) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            for _ in 0..<builder.integer(6, 9) {
                builder.click(column: 2, row: 0)
                builder.wander(seconds: builder.uniform(2, 4.5), tileRadius: 1)
                if builder.chance(0.7) {
                    builder.cancel()
                } else {
                    builder.click(column: 5, row: 3)
                }
                builder.pause(1, 3.5)
            }
            return onset
        },
        TraceScenario(name: "stuck: tutorial tab and back, undoing", isStuck: true, isDeliberatelyHard: false) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            for _ in 0..<builder.integer(3, 5) {
                builder.browserTrip(awaySeconds: builder.uniform(5, 18)) { awayBuilder in
                    awayBuilder.scroll(ticks: awayBuilder.integer(2, 8), ticksPerSecond: 8)
                }
                builder.click(column: 4, row: 3)
                builder.keys(count: 1, keysPerSecond: 4)
                builder.wander(seconds: builder.uniform(2, 5), tileRadius: 1)
                builder.click()
                builder.pause(1, 4)
                builder.undo()
                builder.pause(1, 3)
            }
            return onset
        },
        TraceScenario(name: "stuck: flipping a mode back and forth", isStuck: true, isDeliberatelyHard: false) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            for _ in 0..<builder.integer(6, 9) {
                builder.modeToggle()
                builder.pause(1, 3)
                builder.click(column: 3 + builder.integer(0, 1), row: 3)
                builder.wander(seconds: builder.uniform(1, 3), tileRadius: 1)
            }
            return onset
        },
        TraceScenario(name: "stuck: starting a tool and cancelling it", isStuck: true, isDeliberatelyHard: false) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            for _ in 0..<builder.integer(6, 9) {
                builder.keys(count: 1, keysPerSecond: 4)
                builder.wander(seconds: builder.uniform(1.5, 4), tileRadius: 1)
                builder.cancel()
                builder.pause(1, 4)
            }
            return onset
        },
        TraceScenario(name: "stuck: clicking one control over and over", isStuck: true, isDeliberatelyHard: false) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            for _ in 0..<builder.integer(7, 10) {
                builder.click(column: 7, row: 1)
                builder.pause(0.8, 2)
                builder.moveTo(column: 4, row: 3)
                builder.wander(seconds: builder.uniform(1, 3), tileRadius: 1)
                builder.pause(0.5, 2)
            }
            return onset
        },
        TraceScenario(name: "hard stuck: two undos, circling, then frozen", isStuck: true, isDeliberatelyHard: true) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            builder.click(column: 4, row: 3)
            builder.pause(1, 3)
            builder.undo()
            builder.wander(seconds: builder.uniform(8, 14), tileRadius: 1)
            builder.undo()
            builder.pause(12, 25)
            return onset
        },
        TraceScenario(name: "hard stuck: silent, staring at the screen", isStuck: true, isDeliberatelyHard: true) { builder in
            normalWorkLeadIn(&builder)
            let onset = builder.currentTime
            builder.click(column: 4, row: 3)
            builder.pause(20, 45)
            builder.wander(seconds: 2, tileRadius: 1)
            builder.pause(15, 30)
            return onset
        }
    ]

    static let busyScenarios: [TraceScenario] = [
        TraceScenario(name: "busy: coding, occasional undo", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(14, 22) {
                builder.keys(count: builder.integer(30, 90), keysPerSecond: builder.uniform(5, 9))
                builder.pause(1, 6)
                if builder.chance(0.5) {
                    builder.undo()
                    builder.pause(0.3, 1.2)
                    builder.keys(count: builder.integer(8, 20), keysPerSecond: 7)
                }
                if builder.chance(0.3) {
                    builder.click(column: builder.integer(1, 6), row: builder.integer(1, 5))
                }
            }
            return nil
        },
        TraceScenario(name: "busy: rewriting a paragraph", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(10, 16) {
                builder.keys(count: builder.integer(12, 40), keysPerSecond: builder.uniform(4, 7))
                builder.pause(2, 9)
                if builder.chance(0.7) {
                    builder.undo()
                    builder.pause(1, 4)
                }
                if builder.chance(0.3) {
                    builder.undo()
                    builder.pause(3, 8)
                }
            }
            return nil
        },
        TraceScenario(name: "hard busy: painter, undoing every other stroke", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(50, 80) {
                builder.drag(seconds: builder.uniform(0.6, 1.8))
                builder.pause(0.2, 0.8)
                if builder.chance(0.45) {
                    builder.undo()
                    builder.pause(0.2, 0.8)
                }
                if builder.chance(0.05) {
                    builder.moveTo(column: builder.integer(1, 7), row: builder.integer(1, 5))
                }
            }
            return nil
        },
        TraceScenario(name: "hard busy: modelling in Blender, going well", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(35, 55) {
                switch builder.integer(0, 5) {
                case 0:
                    builder.click(column: builder.integer(2, 7), row: builder.integer(1, 5))
                    builder.pause(0.3, 1.2)
                    builder.keys(count: builder.integer(1, 3), keysPerSecond: 5)
                    builder.wander(seconds: builder.uniform(0.5, 2), tileRadius: 1)
                    builder.click()
                case 1:
                    builder.drag(seconds: builder.uniform(0.6, 2))
                case 2:
                    builder.modeToggle()
                    builder.pause(0.5, 2)
                case 3:
                    builder.scroll(ticks: builder.integer(3, 10), ticksPerSecond: 12)
                case 4:
                    builder.keys(count: builder.integer(2, 5), keysPerSecond: 5)
                default:
                    builder.click(column: builder.integer(0, 8), row: 0)
                    builder.pause(0.5, 1.5)
                    builder.click(column: builder.integer(0, 8), row: builder.integer(1, 3))
                }
                builder.pause(0.5, 2.5)
                if builder.chance(0.1) {
                    builder.undo()
                    builder.pause(0.5, 1.5)
                }
            }
            return nil
        },
        TraceScenario(name: "busy: cutting video in an editor", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(50, 80) {
                builder.click(column: builder.integer(0, 8), row: builder.integer(3, 5))
                builder.keys(count: builder.integer(1, 4), keysPerSecond: 6)
                builder.pause(0.4, 1.8)
                if builder.chance(0.3) {
                    builder.drag(seconds: builder.uniform(0.4, 1.2))
                }
                if builder.chance(0.08) {
                    builder.undo()
                }
            }
            return nil
        },
        TraceScenario(name: "hard busy: holding undo to rewind", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(3, 5) {
                builder.keys(count: builder.integer(20, 40), keysPerSecond: 6)
                builder.pause(2, 6)
                for _ in 0..<builder.integer(6, 14) {
                    builder.undo()
                    builder.pause(0.15, 0.4)
                }
                builder.pause(2, 6)
                builder.click(column: builder.integer(1, 6), row: builder.integer(1, 5))
            }
            return nil
        },
        TraceScenario(name: "busy: reading documentation", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(12, 20) {
                builder.scroll(ticks: builder.integer(10, 40), ticksPerSecond: 15)
                builder.pause(4, 18)
                if builder.chance(0.4) {
                    builder.wander(seconds: builder.uniform(1, 4), tileRadius: 1)
                }
                if builder.chance(0.2) {
                    builder.click(column: builder.integer(1, 6), row: builder.integer(1, 5))
                }
            }
            return nil
        },
        TraceScenario(name: "busy: watching a video", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(4, 7) {
                builder.pause(30, 80)
                builder.wander(seconds: builder.uniform(1, 3), tileRadius: 1)
                if builder.chance(0.5) {
                    builder.click()
                }
                if builder.chance(0.3) {
                    builder.keys(count: 1, keysPerSecond: 3)
                }
            }
            return nil
        },
        TraceScenario(name: "busy: filling in a form", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(16, 28) {
                builder.keys(count: builder.integer(4, 22), keysPerSecond: 6)
                builder.pause(0.2, 1)
                builder.modeToggle()
                builder.pause(0.2, 1.2)
                if builder.chance(0.15) {
                    builder.click(column: builder.integer(2, 6), row: builder.integer(1, 5))
                }
            }
            return nil
        },
        TraceScenario(name: "hard busy: copying from a browser into a doc", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(8, 14) {
                builder.browserTrip(awaySeconds: builder.uniform(6, 25)) { awayBuilder in
                    awayBuilder.scroll(ticks: awayBuilder.integer(5, 25), ticksPerSecond: 12)
                    awayBuilder.drag(seconds: 0.8)
                    awayBuilder.keys(count: 2, keysPerSecond: 8)
                }
                builder.click(column: 3, row: 3)
                builder.keys(count: 2, keysPerSecond: 8)
                builder.keys(count: builder.integer(5, 30), keysPerSecond: 6)
                if builder.chance(0.2) {
                    builder.undo()
                    builder.pause(0.5, 1.5)
                    builder.keys(count: 2, keysPerSecond: 8)
                }
                builder.pause(1, 5)
            }
            return nil
        },
        TraceScenario(name: "hard busy: spreadsheet, moving between two spots", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(30, 45) {
                builder.click(column: 2, row: 3)
                builder.keys(count: builder.integer(2, 7), keysPerSecond: 6)
                builder.pause(0.4, 1.5)
                builder.click(column: 6, row: 3)
                builder.keys(count: builder.integer(2, 7), keysPerSecond: 6)
                builder.pause(0.4, 1.5)
            }
            return nil
        },
        TraceScenario(name: "busy: walked away from the desk", isStuck: false, isDeliberatelyHard: false) { builder in
            normalWorkLeadIn(&builder)
            builder.keys(count: builder.integer(10, 30), keysPerSecond: 6)
            builder.pause(90, 200)
            normalWorkLeadIn(&builder)
            return nil
        },
        TraceScenario(name: "busy: messaging, jumping between apps", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(12, 20) {
                builder.click(column: builder.integer(0, 2), row: builder.integer(1, 5))
                builder.keys(count: builder.integer(8, 45), keysPerSecond: 7)
                builder.pause(1, 6)
                if builder.chance(0.3) {
                    builder.browserTrip(awaySeconds: builder.uniform(3, 20)) { awayBuilder in
                        awayBuilder.scroll(ticks: awayBuilder.integer(3, 12), ticksPerSecond: 12)
                    }
                }
            }
            return nil
        },
        TraceScenario(name: "hard busy: comparing a tweak with undo and redo", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(10, 16) {
                builder.drag(seconds: builder.uniform(1, 2.5))
                builder.pause(1, 3)
                for _ in 0..<builder.integer(1, 3) {
                    builder.undo()
                    builder.pause(1, 2.5)
                    builder.redo()
                    builder.pause(1, 2.5)
                }
                builder.pause(1, 4)
            }
            return nil
        },
        TraceScenario(name: "hard busy: two undos, then it worked", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(4, 7) {
                normalWorkLeadIn(&builder)
                builder.click(column: 4, row: 3)
                builder.wander(seconds: builder.uniform(1, 3), tileRadius: 1)
                builder.undo()
                builder.pause(2, 5)
                builder.click(column: 4, row: 3)
                builder.wander(seconds: builder.uniform(1, 3), tileRadius: 1)
                builder.undo()
                builder.pause(2, 5)
                builder.click(column: 4, row: 3)
                builder.keys(count: builder.integer(3, 8), keysPerSecond: 5)
                builder.pause(8, 20)
            }
            return nil
        },
        TraceScenario(name: "hard busy: vim, escape after every edit", isStuck: false, isDeliberatelyHard: true) { builder in
            for _ in 0..<builder.integer(20, 35) {
                builder.keys(count: builder.integer(4, 30), keysPerSecond: builder.uniform(5, 9))
                builder.cancel()
                builder.pause(0.4, 2.5)
                builder.keys(count: builder.integer(1, 6), keysPerSecond: 6)
                if builder.chance(0.25) {
                    builder.pause(2, 6)
                    builder.cancel()
                }
            }
            return nil
        },
        TraceScenario(name: "busy: stepping through a wizard with Next", isStuck: false, isDeliberatelyHard: false) { builder in
            for _ in 0..<builder.integer(20, 35) {
                builder.pause(1.5, 6)
                builder.click()
                if builder.chance(0.2) {
                    builder.scroll(ticks: builder.integer(3, 10), ticksPerSecond: 12)
                }
            }
            return nil
        }
    ]
}
