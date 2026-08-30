import Foundation

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
                expectedEvents: expectedEvents
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
        expectedEvents: [ExpectedEvent]
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
            let matched = group.compactMap { expected -> (ExpectedEvent, MatchResult)? in
                guard let result = resultsByExpectedID[expected.id],
                      result.classification == .correct,
                      result.actualTimeNanoseconds != nil else { return nil }
                return (expected, result)
            }
            guard matched.count == group.count else { continue }

            let actualTimes = matched.compactMap { $0.1.actualTimeNanoseconds }.map(Double.init)
            guard let earliest = actualTimes.min(), let latest = actualTimes.max() else { continue }
            let center = actualTimes.reduce(0, +) / Double(actualTimes.count)
            spreads.append((latest - earliest) / 1_000_000)
            for (expected, result) in matched {
                guard let actualTime = result.actualTimeNanoseconds else { continue }
                offsetsByVoice[expected.voice, default: []].append((Double(actualTime) - center) / 1_000_000)
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
