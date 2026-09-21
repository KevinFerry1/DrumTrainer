import Foundation

struct AccentEvaluator: Sendable {
    private let relativeContrastRatio = 0.20
    private let neighborLimit = 4

    func evaluate(
        expectedEvents: [ExpectedEvent],
        actualEvents: [PerformanceEvent],
        matchResults: [MatchResult]
    ) -> AccentEvaluation? {
        let accentedEvents = expectedEvents
            .filter(\.isAccent)
            .sorted { lhs, rhs in
                if lhs.sessionTimeNanoseconds != rhs.sessionTimeNanoseconds {
                    return lhs.sessionTimeNanoseconds < rhs.sessionTimeNanoseconds
                }
                return lhs.voice.rawValue < rhs.voice.rawValue
            }
        guard !accentedEvents.isEmpty else { return nil }

        let matchesByExpectedID = Dictionary(uniqueKeysWithValues: matchResults.compactMap { result in
            result.expectedEventID.map { ($0, result) }
        })
        let actualByID = Dictionary(uniqueKeysWithValues: actualEvents.map { ($0.id, $0) })
        let expectedVoices = Dictionary(uniqueKeysWithValues: expectedEvents.map { ($0.id, $0.voice) })
        let playedVelocitiesByExpectedID = Dictionary(uniqueKeysWithValues: matchResults.compactMap { result -> (UUID, Double)? in
            guard result.classification == .correct,
                  let expectedID = result.expectedEventID,
                  let actualID = result.actualEventID,
                  let actual = actualByID[actualID],
                  actual.source == .midi, actual.voice == expectedVoices[expectedID],
                  let velocity = actual.velocity, velocity.isFinite, (0...1).contains(velocity) else { return nil }
            return (expectedID, velocity)
        })

        let results = accentedEvents.map { expected -> AccentResult in
            let minimumVelocity = expected.minimumAccentVelocity
            let authoredContrast = expected.minimumAccentContrast
            guard let match = matchesByExpectedID[expected.id],
                  match.classification == .correct,
                  let actualID = match.actualEventID,
                  let actual = actualByID[actualID] else {
                return AccentResult(
                    expectedEventID: expected.id,
                    actualEventID: matchesByExpectedID[expected.id]?.actualEventID,
                    voice: expected.voice,
                    minimumVelocity: minimumVelocity,
                    baselineVelocity: nil,
                    requiredContrast: authoredContrast,
                    requiredVelocity: minimumVelocity,
                    usedMinimumOnly: false,
                    actualVelocity: nil,
                    classification: .missed
                )
            }
            guard let velocity = actual.velocity else {
                return AccentResult(
                    expectedEventID: expected.id,
                    actualEventID: actualID,
                    voice: expected.voice,
                    minimumVelocity: minimumVelocity,
                    baselineVelocity: nil,
                    requiredContrast: authoredContrast,
                    requiredVelocity: minimumVelocity,
                    usedMinimumOnly: false,
                    actualVelocity: nil,
                    classification: .velocityUnavailable
                )
            }

            let baseline = localBaselineVelocity(
                for: expected,
                expectedEvents: expectedEvents,
                playedVelocitiesByExpectedID: playedVelocitiesByExpectedID
            )
            let requiredContrast = baseline.flatMap { baseline in
                authoredContrast.map { max($0, baseline * relativeContrastRatio) }
            }
            let contrastTarget = baseline.flatMap { baseline in
                requiredContrast.map { baseline + $0 }
            }
            let requiredVelocity = [minimumVelocity, contrastTarget].compactMap { $0 }.max()
            let minimumPassed = minimumVelocity.map { velocity >= $0 } ?? true

            let classification: AccentResultClassification
            let usedMinimumOnly: Bool
            if authoredContrast != nil, baseline == nil {
                usedMinimumOnly = minimumVelocity != nil
                classification = minimumVelocity == nil
                    ? .baselineUnavailable
                    : (minimumPassed ? .achieved : .belowThreshold)
            } else if !minimumPassed {
                usedMinimumOnly = false
                classification = .belowThreshold
            } else if let requiredContrast, let baseline,
                      velocity - baseline < requiredContrast {
                usedMinimumOnly = false
                classification = .insufficientContrast
            } else {
                usedMinimumOnly = false
                classification = .achieved
            }

            return AccentResult(
                expectedEventID: expected.id,
                actualEventID: actualID,
                voice: expected.voice,
                minimumVelocity: minimumVelocity,
                baselineVelocity: baseline,
                requiredContrast: requiredContrast ?? authoredContrast,
                requiredVelocity: requiredVelocity,
                usedMinimumOnly: usedMinimumOnly,
                actualVelocity: velocity,
                classification: classification
            )
        }
        let expectedCount = results.count
        let achievedCount = results.count { $0.classification == .achieved }
        let belowTargetCount = results.count {
            $0.classification == .belowThreshold || $0.classification == .insufficientContrast
        }
        return AccentEvaluation(
            metrics: AccentMetrics(
                expectedCount: expectedCount,
                achievedCount: achievedCount,
                belowThresholdCount: belowTargetCount,
                missedCount: results.count { $0.classification == .missed },
                velocityUnavailableCount: results.count { $0.classification == .velocityUnavailable },
                baselineUnavailableCount: results.count { $0.classification == .baselineUnavailable },
                accuracy: Double(achievedCount) / Double(expectedCount)
            ),
            results: results
        )
    }

    private func localBaselineVelocity(
        for accent: ExpectedEvent,
        expectedEvents: [ExpectedEvent],
        playedVelocitiesByExpectedID: [UUID: Double]
    ) -> Double? {
        let nearby = expectedEvents
            .filter { !$0.isAccent && !$0.isGhost && $0.voice == accent.voice }
            .compactMap { event -> (distance: UInt64, velocity: Double)? in
                guard let velocity = playedVelocitiesByExpectedID[event.id] else { return nil }
                let distance = event.sessionTimeNanoseconds >= accent.sessionTimeNanoseconds
                    ? (UInt64(bitPattern: event.sessionTimeNanoseconds) &- UInt64(bitPattern: accent.sessionTimeNanoseconds))
                    : (UInt64(bitPattern: accent.sessionTimeNanoseconds) &- UInt64(bitPattern: event.sessionTimeNanoseconds))
                return (distance, velocity)
            }
            .sorted { lhs, rhs in
                lhs.distance == rhs.distance ? lhs.velocity < rhs.velocity : lhs.distance < rhs.distance
            }
            .prefix(neighborLimit)
            .map(\.velocity)
            .sorted()
        guard !nearby.isEmpty else { return nil }
        let middle = nearby.count / 2
        if nearby.count.isMultiple(of: 2) {
            return (nearby[middle - 1] + nearby[middle]) / 2
        }
        return nearby[middle]
    }
}

struct GhostEvaluator: Sendable {
    private let relativeContrastRatio = 0.20
    private let neighborLimit = 4

    func evaluate(
        expectedEvents: [ExpectedEvent],
        actualEvents: [PerformanceEvent],
        matchResults: [MatchResult]
    ) -> GhostEvaluation? {
        let ghostEvents = expectedEvents
            .filter(\.isGhost)
            .sorted { lhs, rhs in
                if lhs.sessionTimeNanoseconds != rhs.sessionTimeNanoseconds {
                    return lhs.sessionTimeNanoseconds < rhs.sessionTimeNanoseconds
                }
                return lhs.voice.rawValue < rhs.voice.rawValue
            }
        guard !ghostEvents.isEmpty else { return nil }

        let matchesByExpectedID = Dictionary(uniqueKeysWithValues: matchResults.compactMap { result in
            result.expectedEventID.map { ($0, result) }
        })
        let actualByID = Dictionary(uniqueKeysWithValues: actualEvents.map { ($0.id, $0) })
        let expectedVoices = Dictionary(uniqueKeysWithValues: expectedEvents.map { ($0.id, $0.voice) })
        let playedVelocitiesByExpectedID = Dictionary(uniqueKeysWithValues: matchResults.compactMap { result -> (UUID, Double)? in
            guard result.classification == .correct,
                  let expectedID = result.expectedEventID,
                  let actualID = result.actualEventID,
                  let actual = actualByID[actualID],
                  actual.source == .midi, actual.voice == expectedVoices[expectedID],
                  let velocity = actual.velocity, velocity.isFinite, (0...1).contains(velocity) else { return nil }
            return (expectedID, velocity)
        })

        let results = ghostEvents.map { expected -> GhostResult in
            let maximumVelocity = expected.maximumGhostVelocity
            let authoredContrast = expected.minimumGhostContrast
            guard let match = matchesByExpectedID[expected.id],
                  match.classification == .correct,
                  let actualID = match.actualEventID,
                  let actual = actualByID[actualID] else {
                return GhostResult(
                    expectedEventID: expected.id,
                    actualEventID: matchesByExpectedID[expected.id]?.actualEventID,
                    voice: expected.voice,
                    maximumVelocity: maximumVelocity,
                    baselineVelocity: nil,
                    requiredContrast: authoredContrast,
                    requiredVelocity: maximumVelocity,
                    usedMaximumOnly: false,
                    actualVelocity: nil,
                    classification: .missed
                )
            }
            guard actual.source == .midi, actual.voice == expected.voice,
                  let velocity = actual.velocity, velocity.isFinite, (0...1).contains(velocity) else {
                return GhostResult(
                    expectedEventID: expected.id,
                    actualEventID: actualID,
                    voice: expected.voice,
                    maximumVelocity: maximumVelocity,
                    baselineVelocity: nil,
                    requiredContrast: authoredContrast,
                    requiredVelocity: maximumVelocity,
                    usedMaximumOnly: false,
                    actualVelocity: nil,
                    classification: .velocityUnavailable
                )
            }

            let baseline = localBaselineVelocity(
                for: expected,
                expectedEvents: expectedEvents,
                playedVelocitiesByExpectedID: playedVelocitiesByExpectedID
            )
            let requiredContrast = baseline.flatMap { baseline in
                authoredContrast.map { max($0, baseline * relativeContrastRatio) }
            }
            let contrastTarget = baseline.flatMap { baseline in
                requiredContrast.map { baseline - $0 }
            }
            let requiredVelocity = [maximumVelocity, contrastTarget].compactMap { $0 }.min()
            let maximumPassed = maximumVelocity.map { velocity <= $0 + 1e-12 } ?? true

            let classification: GhostResultClassification
            let usedMaximumOnly: Bool
            if authoredContrast != nil, baseline == nil {
                usedMaximumOnly = maximumVelocity != nil
                classification = maximumVelocity == nil
                    ? .baselineUnavailable
                    : (maximumPassed ? .achieved : .aboveThreshold)
            } else if !maximumPassed {
                usedMaximumOnly = false
                classification = .aboveThreshold
            } else if let requiredContrast, let baseline,
                      baseline - velocity + 1e-12 < requiredContrast {
                usedMaximumOnly = false
                classification = .insufficientContrast
            } else {
                usedMaximumOnly = false
                classification = .achieved
            }

            return GhostResult(
                expectedEventID: expected.id,
                actualEventID: actualID,
                voice: expected.voice,
                maximumVelocity: maximumVelocity,
                baselineVelocity: baseline,
                requiredContrast: requiredContrast ?? authoredContrast,
                requiredVelocity: requiredVelocity,
                usedMaximumOnly: usedMaximumOnly,
                actualVelocity: velocity,
                classification: classification
            )
        }
        let expectedCount = results.count
        let achievedCount = results.count { $0.classification == .achieved }
        let belowTargetCount = results.count {
            $0.classification == .aboveThreshold || $0.classification == .insufficientContrast
        }
        return GhostEvaluation(
            metrics: GhostMetrics(
                expectedCount: expectedCount,
                achievedCount: achievedCount,
                aboveThresholdCount: belowTargetCount,
                missedCount: results.count { $0.classification == .missed },
                velocityUnavailableCount: results.count { $0.classification == .velocityUnavailable },
                baselineUnavailableCount: results.count { $0.classification == .baselineUnavailable },
                accuracy: Double(achievedCount) / Double(expectedCount)
            ),
            results: results
        )
    }

    private func localBaselineVelocity(
        for ghost: ExpectedEvent,
        expectedEvents: [ExpectedEvent],
        playedVelocitiesByExpectedID: [UUID: Double]
    ) -> Double? {
        let nearby = expectedEvents
            .filter { !$0.isGhost && !$0.isAccent && $0.voice == ghost.voice }
            .compactMap { event -> (distance: UInt64, velocity: Double)? in
                guard let velocity = playedVelocitiesByExpectedID[event.id] else { return nil }
                let distance = event.sessionTimeNanoseconds >= ghost.sessionTimeNanoseconds
                    ? (UInt64(bitPattern: event.sessionTimeNanoseconds) &- UInt64(bitPattern: ghost.sessionTimeNanoseconds))
                    : (UInt64(bitPattern: ghost.sessionTimeNanoseconds) &- UInt64(bitPattern: event.sessionTimeNanoseconds))
                return (distance, velocity)
            }
            .sorted { lhs, rhs in
                lhs.distance == rhs.distance ? lhs.velocity < rhs.velocity : lhs.distance < rhs.distance
            }
            .prefix(neighborLimit)
            .map(\.velocity)
            .sorted()
        guard !nearby.isEmpty else { return nil }
        let middle = nearby.count / 2
        if nearby.count.isMultiple(of: 2) {
            return (nearby[middle - 1] + nearby[middle]) / 2
        }
        return nearby[middle]
    }
}

struct ScoringMetricsCalculator: Sendable {
    func calculate(
        from results: [MatchResult],
        expectedEvents: [ExpectedEvent] = [],
        actualEvents: [PerformanceEvent] = []
    ) -> AggregateMetrics {
        let totalExpected = results.count { $0.expectedEventID != nil }
        let totalPlayed = results.count { $0.actualEventID != nil }
        let correctCount = results.count { $0.classification == .correct }
        let missedCount = results.count { $0.classification == .missed }
        let extraCount = results.count { $0.classification == .extra }
        let wrongVoiceCount = results.count { $0.classification == .wrongVoice }
        let ambiguousCount = results.count { $0.classification == .ambiguous }

        let correctOffsets = results.compactMap { result -> Double? in
            result.classification == .correct ? result.signedOffsetMilliseconds : nil
        }
        let absoluteOffsets = correctOffsets.map(abs)
        let meanSigned = mean(correctOffsets)
        let meanAbsolute = mean(absoluteOffsets)
        let medianAbsolute = median(absoluteOffsets)
        let standardDeviation = populationStandardDeviation(correctOffsets)

        let expectedByID = Dictionary(uniqueKeysWithValues: expectedEvents.map { ($0.id, $0) })
        let actualByID = Dictionary(uniqueKeysWithValues: actualEvents.map { ($0.id, $0) })

        return AggregateMetrics(
            totalExpected: totalExpected,
            totalPlayed: totalPlayed,
            correctCount: correctCount,
            missedCount: missedCount,
            extraCount: extraCount,
            wrongVoiceCount: wrongVoiceCount,
            ambiguousCount: ambiguousCount,
            recall: totalExpected == 0 ? 0 : Double(correctCount) / Double(totalExpected),
            precision: totalPlayed == 0 ? 0 : Double(correctCount) / Double(totalPlayed),
            meanSignedOffsetMilliseconds: meanSigned,
            meanAbsoluteErrorMilliseconds: meanAbsolute,
            medianAbsoluteErrorMilliseconds: medianAbsolute,
            timingStandardDeviationMilliseconds: standardDeviation,
            earlyCount: correctOffsets.count { $0 < 0 },
            lateCount: correctOffsets.count { $0 > 0 },
            longestCleanStreak: longestCleanStreak(in: results),
            perVoice: perVoiceMetrics(
                results: results,
                expectedEvents: expectedEvents,
                actualEvents: actualEvents,
                expectedByID: expectedByID,
                actualByID: actualByID
            ),
            limbSynchronization: limbSynchronizationMetrics(
                results: results,
                expectedEvents: expectedEvents,
                actualByID: actualByID
            )
        )
    }

    func timingBand(for result: MatchResult) -> TimingBand {
        guard result.classification == .correct,
              let error = result.absoluteTimingErrorMilliseconds else { return .unmatched }
        return switch error {
        case ...20: TimingBand.tight
        case ...40: TimingBand.good
        case ...70: TimingBand.acceptable
        default: TimingBand.loose
        }
    }

    private func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func populationStandardDeviation(_ values: [Double]) -> Double? {
        guard let average = mean(values) else { return nil }
        let variance = values.reduce(0) { partial, value in
            partial + pow(value - average, 2)
        } / Double(values.count)
        return sqrt(variance)
    }

    private func perVoiceMetrics(
        results: [MatchResult],
        expectedEvents: [ExpectedEvent],
        actualEvents: [PerformanceEvent],
        expectedByID: [UUID: ExpectedEvent],
        actualByID: [UUID: PerformanceEvent]
    ) -> [VoiceMetrics] {
        guard !expectedEvents.isEmpty || !actualEvents.isEmpty else { return [] }
        let voices = Set(expectedEvents.map(\.voice) + actualEvents
            .filter { $0.source != .metronome && $0.voice != .metronome }
            .map(\.voice))
        let resultsByActualID = Dictionary(uniqueKeysWithValues: results.compactMap { result in
            result.actualEventID.map { ($0, result) }
        })
        let playedCounts = actualEvents.reduce(into: [DrumVoice: Int]()) { counts, actual in
            guard actual.source != .metronome, actual.voice != .metronome else { return }
            let result = resultsByActualID[actual.id]
            let creditedVoice: DrumVoice
            if let result,
               result.classification == .correct || result.classification == .ambiguous,
               let expectedID = result.expectedEventID,
               let expected = expectedByID[expectedID] {
                creditedVoice = expected.voice
            } else {
                creditedVoice = actual.voice
            }
            counts[creditedVoice, default: 0] += 1
        }

        return voices.sorted(by: voiceSort).map { voice in
            let voiceResults = results.filter { result in
                result.expectedEventID.flatMap { expectedByID[$0] }?.voice == voice
            }
            let correctResults = voiceResults.filter { $0.classification == .correct }
            let correctOffsets = correctResults.compactMap(\.signedOffsetMilliseconds)
            let extraCount = results.count { result in
                guard result.classification == .extra, let actualID = result.actualEventID else { return false }
                return actualByID[actualID]?.voice == voice
            }
            let playedCount = playedCounts[voice, default: 0]
            let expectedCount = voiceResults.count
            let correctCount = correctResults.count

            return VoiceMetrics(
                voice: voice,
                totalExpected: expectedCount,
                totalPlayed: playedCount,
                correctCount: correctCount,
                missedCount: voiceResults.count { $0.classification == .missed },
                extraCount: extraCount,
                wrongVoiceCount: voiceResults.count { $0.classification == .wrongVoice },
                ambiguousCount: voiceResults.count { $0.classification == .ambiguous },
                recall: expectedCount == 0 ? 0 : Double(correctCount) / Double(expectedCount),
                precision: playedCount == 0 ? 0 : Double(correctCount) / Double(playedCount),
                meanSignedOffsetMilliseconds: mean(correctOffsets),
                medianAbsoluteErrorMilliseconds: median(correctOffsets.map(abs)),
                timingStandardDeviationMilliseconds: populationStandardDeviation(correctOffsets)
            )
        }
    }

    private func limbSynchronizationMetrics(
        results: [MatchResult],
        expectedEvents: [ExpectedEvent],
        actualByID: [UUID: PerformanceEvent]
    ) -> LimbSynchronizationMetrics? {
        let eligibleGroups = Dictionary(grouping: expectedEvents.compactMap { event -> (UUID, ExpectedEvent)? in
            event.simultaneousGroupID.map { ($0, event) }
        }, by: \.0)
            .mapValues { $0.map(\.1) }
            .filter { $0.value.count >= 2 }
        guard !eligibleGroups.isEmpty else { return nil }

        let resultsByExpectedID = Dictionary(uniqueKeysWithValues: results.compactMap { result in
            result.expectedEventID.map { ($0, result) }
        })
        var spreads: [Double] = []
        var offsetsByVoice: [DrumVoice: [Double]] = [:]

        for group in eligibleGroups.values {
            let matched = group.compactMap { expected -> (ExpectedEvent, MatchResult, PerformanceEvent)? in
                guard let result = resultsByExpectedID[expected.id],
                      result.classification == .correct,
                      result.actualTimeNanoseconds != nil,
                      let actualID = result.actualEventID,
                      let actual = actualByID[actualID] else { return nil }
                return (expected, result, actual)
            }
            guard matched.count == group.count else { continue }

            // A shared MIDI correction is allowed to move the whole kit relative to the
            // click, but it must never alter the timing relationship between MIDI pads.
            // Mixed microphone/MIDI groups still use corrected times because those inputs
            // travel through genuinely different capture pipelines.
            let useRawMIDITimestamps = matched.allSatisfy { $0.2.source == .midi }
            let actualTimes = matched.compactMap { item -> Double? in
                if useRawMIDITimestamps {
                    return Double(item.2.sessionTimeNanoseconds)
                }
                return item.1.actualTimeNanoseconds.map(Double.init)
            }
            guard let earliest = actualTimes.min(), let latest = actualTimes.max() else { continue }
            let center = actualTimes.reduce(0, +) / Double(actualTimes.count)
            spreads.append((latest - earliest) / 1_000_000)
            for (expected, result, actual) in matched {
                let actualTime = useRawMIDITimestamps
                    ? Double(actual.sessionTimeNanoseconds)
                    : result.actualTimeNanoseconds.map(Double.init)
                guard let actualTime else { continue }
                offsetsByVoice[expected.voice, default: []].append((actualTime - center) / 1_000_000)
            }
        }

        let voiceOffsets = offsetsByVoice.map { voice, offsets in
            VoiceSynchronizationOffset(
                voice: voice,
                sampleCount: offsets.count,
                meanOffsetFromGroupCenterMilliseconds: mean(offsets) ?? 0,
                medianOffsetFromGroupCenterMilliseconds: median(offsets) ?? 0
            )
        }.sorted { voiceSort($0.voice, $1.voice) }

        return LimbSynchronizationMetrics(
            eligibleGroupCount: eligibleGroups.count,
            completedGroupCount: spreads.count,
            averageSpreadMilliseconds: mean(spreads),
            medianSpreadMilliseconds: median(spreads),
            worstSpreadMilliseconds: spreads.max(),
            voiceOffsets: voiceOffsets
        )
    }

    private func voiceSort(_ lhs: DrumVoice, _ rhs: DrumVoice) -> Bool {
        let order = Dictionary(uniqueKeysWithValues: DrumVoice.allCases.enumerated().map { ($0.element, $0.offset) })
        return (order[lhs] ?? Int.max) < (order[rhs] ?? Int.max)
    }

    private func longestCleanStreak(in results: [MatchResult]) -> Int {
        let ordered = results.sorted { lhs, rhs in
            let leftTime = lhs.expectedTimeNanoseconds ?? lhs.actualTimeNanoseconds ?? Int64.max
            let rightTime = rhs.expectedTimeNanoseconds ?? rhs.actualTimeNanoseconds ?? Int64.max
            if leftTime != rightTime { return leftTime < rightTime }
            return lhs.classification.rawValue < rhs.classification.rawValue
        }

        var longest = 0
        var current = 0
        for result in ordered {
            if result.classification == .correct {
                current += 1
                longest = max(longest, current)
            } else {
                current = 0
            }
        }
        return longest
    }
}

struct StableTimingBiasEvaluator: Sendable {
    private let minimumSamples = 8
    private let minimumBiasMilliseconds = 30.0
    private let maximumBiasMilliseconds = 80.0
    private let maximumMedianDeviationMilliseconds = 12.0
    private let maximumAdjustedMedianErrorMilliseconds = 25.0
    private let minimumSameSideRatio = 0.8

    func evaluate(_ results: [MatchResult]) -> StableTimingBiasEvaluation? {
        let offsets = results.compactMap { result -> Double? in
            guard result.classification == .correct,
                  let offset = result.signedOffsetMilliseconds,
                  offset.isFinite else { return nil }
            return offset
        }
        guard offsets.count >= minimumSamples,
              let bias = median(offsets),
              (minimumBiasMilliseconds...maximumBiasMilliseconds).contains(abs(bias)) else { return nil }

        let sameSideCount = offsets.count { bias >= 0 ? $0 >= 0 : $0 <= 0 }
        guard Double(sameSideCount) / Double(offsets.count) >= minimumSameSideRatio else { return nil }

        let centeredErrors = offsets.map { abs($0 - bias) }
        guard let medianDeviation = median(centeredErrors),
              medianDeviation <= maximumMedianDeviationMilliseconds,
              let rawMedianError = median(offsets.map(abs)),
              let adjustedMedianError = median(centeredErrors),
              rawMedianError > maximumAdjustedMedianErrorMilliseconds,
              adjustedMedianError <= maximumAdjustedMedianErrorMilliseconds else { return nil }

        return StableTimingBiasEvaluation(
            sampleCount: offsets.count,
            biasMilliseconds: bias,
            medianAbsoluteDeviationMilliseconds: medianDeviation,
            rawMedianAbsoluteErrorMilliseconds: rawMedianError,
            adjustedMedianAbsoluteErrorMilliseconds: adjustedMedianError
        )
    }

    private func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}

struct PracticeResultCoach: Sendable {
    func summarize(_ outcome: PracticeSessionOutcome) -> PracticeCoachingSummary {
        let stableTiming = outcome.stableTimingBiasEvaluation
        var observations: [String] = []

        if let stableTiming {
            observations.append(
                "Your groove was steady despite a shared \(signedMilliseconds(stableTiming.biasMilliseconds)) raw offset, so grading used the \(milliseconds(stableTiming.adjustedMedianAbsoluteErrorMilliseconds)) groove error."
            )
        }

        let accents = outcome.accentEvaluation
        let ghosts = outcome.ghostEvaluation
        let voices = outcome.metrics.perVoice
            .filter { $0.totalExpected > 0 }
            .sorted { lhs, rhs in
                if lhs.totalExpected != rhs.totalExpected { return lhs.totalExpected > rhs.totalExpected }
                return voiceIndex(lhs.voice) < voiceIndex(rhs.voice)
            }
            .prefix(3)

        for voice in voices {
            observations.append(voiceObservation(
                voice,
                stableTiming: stableTiming,
                accentEvaluation: accents,
                ghostEvaluation: ghosts
            ))
        }

        let overview = observations.isEmpty
            ? "There were not enough graded notes to produce a useful summary."
            : observations.joined(separator: " ")
        return PracticeCoachingSummary(
            overview: overview,
            nextStep: nextStep(
                outcome,
                stableTiming: stableTiming,
                accentEvaluation: accents,
                ghostEvaluation: ghosts
            )
        )
    }

    private func voiceObservation(
        _ metrics: VoiceMetrics,
        stableTiming: StableTimingBiasEvaluation?,
        accentEvaluation: AccentEvaluation?,
        ghostEvaluation: GhostEvaluation?
    ) -> String {
        let effectiveAccuracy = min(metrics.recall, metrics.precision)
        let accuracyPhrase: String
        switch effectiveAccuracy {
        case 0.95...: accuracyPhrase = "was very accurate"
        case 0.85...: accuracyPhrase = "was mostly accurate"
        case 0.70...: accuracyPhrase = "was uneven"
        default: accuracyPhrase = "accuracy needs work"
        }

        var clauses = [
            "\(metrics.voice.displayName) \(accuracyPhrase) (\(percent(metrics.recall)) recall)"
        ]
        if metrics.precision < 0.85, metrics.extraCount > 0 {
            clauses.append("\(metrics.extraCount) extra \(metrics.extraCount == 1 ? "hit" : "hits")")
        }
        if stableTiming == nil, let median = metrics.medianAbsoluteErrorMilliseconds {
            switch median {
            case ...20: clauses.append("timing was on target")
            case ...40: clauses.append("timing was mostly on target")
            case ...70: clauses.append("timing was loose")
            default: clauses.append("timing was well off the click")
            }
        }

        if let dynamic = accentEvaluation?.voiceAccuracy(for: metrics.voice), dynamic.accuracy < 0.9 {
            clauses.append(accentObservation(for: metrics.voice, evaluation: accentEvaluation, accuracy: dynamic.accuracy))
        }
        if let dynamic = ghostEvaluation?.voiceAccuracy(for: metrics.voice), dynamic.accuracy < 0.9 {
            clauses.append(ghostObservation(for: metrics.voice, evaluation: ghostEvaluation, accuracy: dynamic.accuracy))
        }
        return clauses.joined(separator: "; ") + "."
    }

    private func accentObservation(
        for voice: DrumVoice,
        evaluation: AccentEvaluation?,
        accuracy: Double
    ) -> String {
        let results = evaluation?.results.filter { $0.voice == voice } ?? []
        let tooSoft = results.count { $0.classification == .belowThreshold }
        let insufficientContrast = results.count { $0.classification == .insufficientContrast }
        if tooSoft > insufficientContrast, tooSoft > 0 {
            return "accent accuracy was \(dynamicQuality(accuracy)) because accents were often too soft"
        }
        if insufficientContrast > 0 {
            return "accent accuracy was \(dynamicQuality(accuracy)) because accents did not stand out enough"
        }
        return "accent accuracy was \(dynamicQuality(accuracy))"
    }

    private func ghostObservation(
        for voice: DrumVoice,
        evaluation: GhostEvaluation?,
        accuracy: Double
    ) -> String {
        let results = evaluation?.results.filter { $0.voice == voice } ?? []
        let tooLoud = results.count { $0.classification == .aboveThreshold }
        let insufficientContrast = results.count { $0.classification == .insufficientContrast }
        if tooLoud > insufficientContrast, tooLoud > 0 {
            return "ghost-note accuracy was \(dynamicQuality(accuracy)) because ghost notes were often too loud"
        }
        if insufficientContrast > 0 {
            return "ghost-note accuracy was \(dynamicQuality(accuracy)) because ghost notes were not quiet enough relative to normal hits"
        }
        return "ghost-note accuracy was \(dynamicQuality(accuracy))"
    }

    private func nextStep(
        _ outcome: PracticeSessionOutcome,
        stableTiming: StableTimingBiasEvaluation?,
        accentEvaluation: AccentEvaluation?,
        ghostEvaluation: GhostEvaluation?
    ) -> String {
        if let synchronizationTip = snareHatSynchronizationTip(outcome) {
            return synchronizationTip
        }
        if let stableTiming {
            return "Re-run hit timing alignment for the active drums; the shared \(signedMilliseconds(stableTiming.biasMilliseconds)) offset looks more like fixed latency than random timing."
        }

        let dynamicIssues = outcome.metrics.perVoice.compactMap { metrics -> (Double, String)? in
            if let accent = accentEvaluation?.voiceAccuracy(for: metrics.voice), accent.accuracy < 0.7 {
                return (accent.accuracy, "Exaggerate the \(metrics.voice.displayName.lowercased()) accents for one slow run, making each one clearly louder than the nearby normal hits.")
            }
            if let ghost = ghostEvaluation?.voiceAccuracy(for: metrics.voice), ghost.accuracy < 0.7 {
                return (ghost.accuracy, "Play the \(metrics.voice.displayName.lowercased()) ghost notes noticeably softer for one slow run while keeping their placement unchanged.")
            }
            return nil
        }
        if let issue = dynamicIssues.min(by: { $0.0 < $1.0 }) {
            return issue.1
        }

        if let weakest = outcome.metrics.perVoice
            .filter({ $0.totalExpected > 0 })
            .min(by: { min($0.recall, $0.precision) < min($1.recall, $1.precision) }),
           min(weakest.recall, weakest.precision) < 0.85 {
            return "Slow the exercise down and focus on the \(weakest.voice.displayName.lowercased()) part alone until the misses and extra hits disappear."
        }
        if let loosest = outcome.metrics.perVoice
            .compactMap({ metrics in metrics.medianAbsoluteErrorMilliseconds.map { (metrics, $0) } })
            .max(by: { $0.1 < $1.1 }), loosest.1 > 40 {
            return "Loop the \(loosest.0.voice.displayName.lowercased()) part slowly and aim for the center of each click before raising the tempo."
        }
        return "Repeat once at the same tempo and try to preserve the same relaxed spacing."
    }

    private func snareHatSynchronizationTip(_ outcome: PracticeSessionOutcome) -> String? {
        guard let synchronization = outcome.metrics.limbSynchronization,
              synchronization.completedGroupCount > 0 else { return nil }
        let grouped = Dictionary(grouping: outcome.pattern.expectedEvents.compactMap { event in
            event.simultaneousGroupID.map { ($0, event.voice) }
        }, by: \.0).mapValues { Set($0.map(\.1)) }
        let expectedTogether = grouped.values.contains { voices in
            voices.contains(.snare) && voices.contains(where: isHiHat)
        }
        guard expectedTogether,
              let snare = synchronization.voiceOffsets.first(where: { $0.voice == .snare }),
              let hat = synchronization.voiceOffsets
                .filter({ isHiHat($0.voice) })
                .max(by: { $0.sampleCount < $1.sampleCount }) else { return nil }
        let separation = snare.medianOffsetFromGroupCenterMilliseconds
            - hat.medianOffsetFromGroupCenterMilliseconds
        guard abs(separation) >= 15 else { return nil }
        let relation = separation > 0 ? "behind" : "ahead of"
        return "Try to land the snare and \(hat.voice.displayName.lowercased()) together; the snare averaged about \(milliseconds(abs(separation))) \(relation) the hat on completed unison hits."
    }

    private func isHiHat(_ voice: DrumVoice) -> Bool {
        voice == .closedHiHat || voice == .openHiHat || voice == .pedalHiHat
    }

    private func dynamicQuality(_ accuracy: Double) -> String {
        accuracy < 0.4 ? "very low" : "inconsistent"
    }

    private func voiceIndex(_ voice: DrumVoice) -> Int {
        DrumVoice.allCases.firstIndex(of: voice) ?? Int.max
    }

    private func percent(_ value: Double) -> String {
        (value * 100).formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func milliseconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    private func signedMilliseconds(_ value: Double) -> String {
        (value > 0 ? "+" : "") + milliseconds(value)
    }
}
