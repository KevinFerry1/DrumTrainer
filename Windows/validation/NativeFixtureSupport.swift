// Minimal app-independent adapters for compiling the actual Swift drum algorithms.
// No matching, scoring, detector or classifier implementation is duplicated here.
import Foundation

enum MusicalTarget { case drum(DrumVoice) }
extension StableTimingBiasEvaluation: Encodable {
    private enum Keys: String, CodingKey { case sampleCount, biasMilliseconds, medianAbsoluteDeviationMilliseconds, rawMedianAbsoluteErrorMilliseconds, adjustedMedianAbsoluteErrorMilliseconds }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(biasMilliseconds, forKey: .biasMilliseconds)
        try c.encode(medianAbsoluteDeviationMilliseconds, forKey: .medianAbsoluteDeviationMilliseconds)
        try c.encode(rawMedianAbsoluteErrorMilliseconds, forKey: .rawMedianAbsoluteErrorMilliseconds)
        try c.encode(adjustedMedianAbsoluteErrorMilliseconds, forKey: .adjustedMedianAbsoluteErrorMilliseconds)
    }
}
struct PracticeSessionOutcome {
    let pattern: PracticePattern
    let actualEvents: [PerformanceEvent]
    let matchResults: [MatchResult]
    let metrics: AggregateMetrics
    var accentEvaluation: AccentEvaluation? { AccentEvaluator().evaluate(expectedEvents: pattern.expectedEvents, actualEvents: actualEvents, matchResults: matchResults) }
    var ghostEvaluation: GhostEvaluation? { GhostEvaluator().evaluate(expectedEvents: pattern.expectedEvents, actualEvents: actualEvents, matchResults: matchResults) }
    var stableTimingBiasEvaluation: StableTimingBiasEvaluation? { StableTimingBiasEvaluator().evaluate(matchResults) }
}

extension PracticeCoachingSummary: Encodable {
    private enum Keys: String, CodingKey { case overview, nextStep }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(overview, forKey: .overview)
        try c.encode(nextStep, forKey: .nextStep)
    }
}

extension TimingAlignmentMeasurement: Encodable {
    private enum Keys: String, CodingKey { case compensationMilliseconds, medianAbsoluteDeviationMilliseconds, sampleCount, referenceCount, missedCount }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(compensationMilliseconds, forKey: .compensationMilliseconds)
        try c.encode(medianAbsoluteDeviationMilliseconds, forKey: .medianAbsoluteDeviationMilliseconds)
        try c.encode(sampleCount, forKey: .sampleCount)
        try c.encode(referenceCount, forKey: .referenceCount)
        try c.encode(missedCount, forKey: .missedCount)
    }
}
