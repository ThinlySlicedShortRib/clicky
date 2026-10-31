//
//  FollowAlongCostMeter.swift
//  leanring-buddy
//
//  Adds up what a lesson really cost, one BrainUsage at a time, and works out
//  what a naive build that looks at the screen constantly would have spent.
//  Every dollar shown comes from a backend-reported figure. Nothing here
//  invents a price: a call with no reported cost makes the total "not
//  reported", and the screen then shows tokens instead of a smaller number.
//

import Foundation

enum FollowAlongBrainCallPurpose: String, Codable {
    case planTranscript = "plan_transcript"
    case planKeyFrames = "plan_key_frames"
    case locateTarget = "locate_target"
    case checkSuccess = "check_success"
    case secondOpinion = "second_opinion"
    case answerQuestion = "answer_question"

    /// Calls that carry a screenshot of the viewer's screen, which is the unit
    /// a naive design would be repeating.
    var looksAtScreen: Bool {
        switch self {
        case .planTranscript, .planKeyFrames:
            return false
        case .locateTarget, .checkSuccess, .secondOpinion, .answerQuestion:
            return true
        }
    }
}

struct FollowAlongLedgerEntry: Codable {
    let purpose: FollowAlongBrainCallPurpose
    let stepIdentifier: String?
    let usage: BrainUsage
}

/// A point-in-time reading of the meter, for the HUD, end card and run log.
struct FollowAlongCostSnapshot: Codable {
    let modelCallCount: Int
    /// Sum of reported costs. Nil if any call reported none.
    let totalCostInUSD: Double?
    let isCostEstimated: Bool
    let totalInputTokens: Int
    let totalOutputTokens: Int
    /// Steps pointed at from the location cache, with no model call.
    let cachedStepsReused: Int
    let isLessonPlanCached: Bool
    /// What building the plan originally cost, when it came from cache.
    let cachedPlanOriginalCostInUSD: Double?
    /// Screenshots compared locally for free.
    let screensLookedAt: Int
    /// Screenshots the local comparison judged worth sending to a model.
    let screensSentToModel: Int
    let elapsedInSeconds: Double
    /// Seconds of lesson times what the main model really cost per look. This
    /// is the like-for-like figure: one model doing everything, every second.
    /// Nil until a real cost has been measured.
    let naiveEstimatedCostInUSD: Double?
    /// The same looks at the cheapest real per-look cost. This is the floor,
    /// shown so the headline figure can't be read as a best case for Clicky.
    let naiveFloorEstimatedCostInUSD: Double?
    let naiveCallCount: Int
}

struct FollowAlongCostLedger {
    /// How often the imagined naive design looks at the screen. One look a
    /// second is deliberately generous to it: a video-rate design would be
    /// roughly thirty times worse.
    static let naiveLooksPerSecond = 1.0

    private(set) var entries: [FollowAlongLedgerEntry] = []
    var cachedStepsReused = 0
    var screensLookedAt = 0
    var isLessonPlanCached = false
    var cachedPlanOriginalCostInUSD: Double?

    mutating func record(purpose: FollowAlongBrainCallPurpose, stepIdentifier: String?, usage: BrainUsage) {
        entries.append(FollowAlongLedgerEntry(purpose: purpose, stepIdentifier: stepIdentifier, usage: usage))
    }

    /// Brings in the plan's calls when the lesson was built during this run,
    /// so a first-time lesson shows what it really cost.
    mutating func recordFreshlyGeneratedPlan(_ generation: FollowAlongLessonGeneration) {
        for brainCall in generation.brainCalls {
            let purpose = FollowAlongBrainCallPurpose(rawValue: brainCall.purpose) ?? .planTranscript
            record(purpose: purpose, stepIdentifier: nil, usage: brainCall.usage)
        }
    }

    func snapshot(elapsedInSeconds: Double) -> FollowAlongCostSnapshot {
        let reportedCosts = entries.map(\.usage.costInUSD)
        let totalCostInUSD: Double? = reportedCosts.contains { $0 == nil }
            ? nil
            : reportedCosts.compactMap { $0 }.reduce(0, +)

        let naiveCallCount = Int((elapsedInSeconds * Self.naiveLooksPerSecond).rounded(.down))
        let meanCostByPurpose = meanCostPerLookByPurpose()
        let mainModelCostPerLook = meanCostByPurpose[.locateTarget]
            ?? meanCostByPurpose[.answerQuestion]
            ?? meanCostByPurpose.values.min()
        let cheapestCostPerLook = meanCostByPurpose.values.min()

        return FollowAlongCostSnapshot(
            modelCallCount: entries.count,
            totalCostInUSD: totalCostInUSD,
            isCostEstimated: entries.contains { $0.usage.isCostEstimated },
            totalInputTokens: entries.compactMap(\.usage.inputTokens).reduce(0, +),
            totalOutputTokens: entries.compactMap(\.usage.outputTokens).reduce(0, +),
            cachedStepsReused: cachedStepsReused,
            isLessonPlanCached: isLessonPlanCached,
            cachedPlanOriginalCostInUSD: cachedPlanOriginalCostInUSD,
            screensLookedAt: screensLookedAt,
            screensSentToModel: entries.filter(\.purpose.looksAtScreen).count,
            elapsedInSeconds: elapsedInSeconds,
            naiveEstimatedCostInUSD: mainModelCostPerLook.map { $0 * Double(naiveCallCount) },
            naiveFloorEstimatedCostInUSD: cheapestCostPerLook.map { $0 * Double(naiveCallCount) },
            naiveCallCount: naiveCallCount
        )
    }

    /// Means rather than single calls, because one prompt cache hit would
    /// otherwise stand in for a whole lesson's looks.
    private func meanCostPerLookByPurpose() -> [FollowAlongBrainCallPurpose: Double] {
        let screenEntries = entries.filter(\.purpose.looksAtScreen)
        let entriesByPurpose = Dictionary(grouping: screenEntries, by: \.purpose)

        return entriesByPurpose.compactMapValues { purposeEntries in
            let costs = purposeEntries.compactMap(\.usage.costInUSD)
            guard !costs.isEmpty else { return nil }
            return costs.reduce(0, +) / Double(costs.count)
        }
    }
}

enum FollowAlongCostFormatting {
    /// Follows the rules in docs/FOUNDATION.md: nil is "not reported", never
    /// zero, and an estimate always says so.
    static func costText(_ costInUSD: Double?, isEstimated: Bool) -> String {
        guard let costInUSD else { return "cost not reported" }
        let amountText = costInUSD < 0.1
            ? String(format: "$%.4f", costInUSD)
            : String(format: "$%.2f", costInUSD)
        return isEstimated ? "\(amountText) est" : amountText
    }

    static func durationText(seconds: Double) -> String {
        let wholeSeconds = Int(seconds.rounded())
        let minutes = wholeSeconds / 60
        let remainingSeconds = wholeSeconds % 60
        return minutes > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(remainingSeconds)s"
    }
}
