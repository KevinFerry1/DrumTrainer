import Foundation

struct EventTimingCompensationKey: Hashable, Sendable {
    let source: EventSource
    let voice: DrumVoice
}

struct EventMatcher: Sendable {
    private let sourceTimingCompensationNanoseconds: [EventSource: Int64]
    private let voiceTimingCompensationNanoseconds: [EventTimingCompensationKey: Int64]

    init(
        sourceTimingCompensationNanoseconds: [EventSource: Int64] = [:],
        voiceTimingCompensationNanoseconds: [EventTimingCompensationKey: Int64] = [:]
    ) {
        self.sourceTimingCompensationNanoseconds = sourceTimingCompensationNanoseconds
        self.voiceTimingCompensationNanoseconds = voiceTimingCompensationNanoseconds
    }

    func match(expected: [ExpectedEvent], actual: [PerformanceEvent]) -> [MatchResult] {
        let expectedEvents = expected.sorted(by: expectedSort)
        let actualEvents = sortedActualEvents(actual
            .filter { $0.source != .metronome && $0.voice != .metronome }
            .map(applyingTimingCompensation))

        let expectedCount = expectedEvents.count
        let actualCount = actualEvents.count
        var costs = Array(
            repeating: Array(repeating: Double.infinity, count: actualCount + 1),
            count: expectedCount + 1
        )
        var predecessors = Array(
            repeating: Array<Transition?>(repeating: nil, count: actualCount + 1),
            count: expectedCount + 1
        )
        costs[0][0] = 0

        for expectedIndex in 0...expectedCount {
            for actualIndex in 0...actualCount {
                let currentCost = costs[expectedIndex][actualIndex]
                guard currentCost.isFinite else { continue }

                if expectedIndex < expectedCount {
                    update(
                        cost: currentCost + 1,
                        transition: .missed,
                        expectedIndex: expectedIndex + 1,
                        actualIndex: actualIndex,
                        costs: &costs,
                        predecessors: &predecessors
                    )
                }

                if actualIndex < actualCount {
                    update(
                        cost: currentCost + 1,
                        transition: .extra,
                        expectedIndex: expectedIndex,
                        actualIndex: actualIndex + 1,
                        costs: &costs,
                        predecessors: &predecessors
                    )
                }

                if expectedIndex < expectedCount, actualIndex < actualCount {
                    let expectedEvent = expectedEvents[expectedIndex]
                    let actualEvent = actualEvents[actualIndex]
                    let error = absoluteDifference(
                        expectedEvent.sessionTimeNanoseconds,
                        actualEvent.sessionTimeNanoseconds
                    )
                    guard error <= UInt64(expectedEvent.matchingToleranceNanoseconds) else { continue }

                    let tolerance = max(1, Double(expectedEvent.matchingToleranceNanoseconds))
                    let normalizedError = min(Double(error) / tolerance, 1)
                    let isCompatible = expectedEvent.accepts(actualEvent.voice)
                    let transition: Transition = isCompatible ? .matchedCorrect : .matchedWrongVoice
                    let matchCost = isCompatible
                        ? normalizedError * 0.49
                        : 1.1 + normalizedError * 0.39

                    update(
                        cost: currentCost + matchCost,
                        transition: transition,
                        expectedIndex: expectedIndex + 1,
                        actualIndex: actualIndex + 1,
                        costs: &costs,
                        predecessors: &predecessors
                    )
                }
            }
        }

        return Array(backtrack(
            expected: expectedEvents,
            actual: actualEvents,
            predecessors: predecessors
        ).reversed())
    }

    private func backtrack(
        expected: [ExpectedEvent],
        actual: [PerformanceEvent],
        predecessors: [[Transition?]]
    ) -> [MatchResult] {
        var results: [MatchResult] = []
        var expectedIndex = expected.count
        var actualIndex = actual.count

        while expectedIndex > 0 || actualIndex > 0 {
            guard let transition = predecessors[expectedIndex][actualIndex] else { break }
            switch transition {
            case .matchedCorrect, .matchedWrongVoice:
                let expectedEvent = expected[expectedIndex - 1]
                let actualEvent = actual[actualIndex - 1]
                let signedOffset = (
                    Double(actualEvent.sessionTimeNanoseconds) - Double(expectedEvent.sessionTimeNanoseconds)
                ) / 1_000_000
                let classification: MatchClassification
                if transition == .matchedWrongVoice {
                    classification = .wrongVoice
                } else if isAmbiguous(expected: expectedEvent, matchedActual: actualEvent, allActual: actual) {
                    classification = .ambiguous
                } else {
                    classification = .correct
                }
                results.append(MatchResult(
                    expectedEventID: expectedEvent.id,
                    actualEventID: actualEvent.id,
                    classification: classification,
                    expectedTimeNanoseconds: expectedEvent.sessionTimeNanoseconds,
                    actualTimeNanoseconds: actualEvent.sessionTimeNanoseconds,
                    signedOffsetMilliseconds: signedOffset
                ))
                expectedIndex -= 1
                actualIndex -= 1

            case .missed:
                let expectedEvent = expected[expectedIndex - 1]
                results.append(MatchResult(
                    expectedEventID: expectedEvent.id,
                    actualEventID: nil,
                    classification: .missed,
                    expectedTimeNanoseconds: expectedEvent.sessionTimeNanoseconds,
                    actualTimeNanoseconds: nil,
                    signedOffsetMilliseconds: nil
                ))
                expectedIndex -= 1

            case .extra:
                let actualEvent = actual[actualIndex - 1]
                results.append(MatchResult(
                    expectedEventID: nil,
                    actualEventID: actualEvent.id,
                    classification: .extra,
                    expectedTimeNanoseconds: nil,
                    actualTimeNanoseconds: actualEvent.sessionTimeNanoseconds,
                    signedOffsetMilliseconds: nil
                ))
                actualIndex -= 1
            }
        }
        return results
    }

    private func isAmbiguous(
        expected: ExpectedEvent,
        matchedActual: PerformanceEvent,
        allActual: [PerformanceEvent]
    ) -> Bool {
        let matchedError = absoluteDifference(
            expected.sessionTimeNanoseconds,
            matchedActual.sessionTimeNanoseconds
        )
        return allActual.lazy.filter { candidate in
            candidate.id != matchedActual.id &&
                expected.accepts(candidate.voice) &&
                absoluteDifference(expected.sessionTimeNanoseconds, candidate.sessionTimeNanoseconds) == matchedError &&
                matchedError <= UInt64(expected.matchingToleranceNanoseconds)
        }.first != nil
    }

    private func update(
        cost: Double,
        transition: Transition,
        expectedIndex: Int,
        actualIndex: Int,
        costs: inout [[Double]],
        predecessors: inout [[Transition?]]
    ) {
        let current = costs[expectedIndex][actualIndex]
        let isCheaper = cost < current - 0.000_000_1
        let isPreferredTie = abs(cost - current) <= 0.000_000_1 &&
            transition.rank < (predecessors[expectedIndex][actualIndex]?.rank ?? Int.max)
        guard isCheaper || isPreferredTie else { return }
        costs[expectedIndex][actualIndex] = cost
        predecessors[expectedIndex][actualIndex] = transition
    }

    private func expectedSort(_ lhs: ExpectedEvent, _ rhs: ExpectedEvent) -> Bool {
        if lhs.sessionTimeNanoseconds != rhs.sessionTimeNanoseconds {
            return lhs.sessionTimeNanoseconds < rhs.sessionTimeNanoseconds
        }
        return lhs.voice.rawValue < rhs.voice.rawValue
    }

    private func actualSort(_ lhs: PerformanceEvent, _ rhs: PerformanceEvent) -> Bool {
        if lhs.sessionTimeNanoseconds != rhs.sessionTimeNanoseconds {
            return lhs.sessionTimeNanoseconds < rhs.sessionTimeNanoseconds
        }
        if lhs.voice != rhs.voice { return lhs.voice.rawValue < rhs.voice.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// Limb hits in a chord arrive a few milliseconds apart. Sorting each tight cluster by
    /// voice keeps the sequence matcher from treating a reversed MIDI/microphone arrival
    /// order as the wrong drum while preserving the raw event timestamps.
    private func sortedActualEvents(_ events: [PerformanceEvent]) -> [PerformanceEvent] {
        let chronological = events.sorted(by: actualSort)
        guard chronological.count > 1 else { return chronological }
        let clusterWindowNanoseconds: UInt64 = 35_000_000
        var result: [PerformanceEvent] = []
        var cluster: [PerformanceEvent] = []

        func appendCluster() {
            result.append(contentsOf: cluster.sorted { lhs, rhs in
                if lhs.voice != rhs.voice { return lhs.voice.rawValue < rhs.voice.rawValue }
                if lhs.sessionTimeNanoseconds != rhs.sessionTimeNanoseconds {
                    return lhs.sessionTimeNanoseconds < rhs.sessionTimeNanoseconds
                }
                return lhs.id.uuidString < rhs.id.uuidString
            })
        }

        for event in chronological {
            if let previous = cluster.last,
               absoluteDifference(previous.sessionTimeNanoseconds, event.sessionTimeNanoseconds) > clusterWindowNanoseconds {
                appendCluster()
                cluster = []
            }
            cluster.append(event)
        }
        appendCluster()
        return result
    }

    private func applyingTimingCompensation(to event: PerformanceEvent) -> PerformanceEvent {
        let voiceKey = EventTimingCompensationKey(source: event.source, voice: event.voice)
        let correction = voiceTimingCompensationNanoseconds[voiceKey]
            ?? sourceTimingCompensationNanoseconds[event.source]
            ?? 0
        let correctedTime: Int64
        let (value, overflow) = event.sessionTimeNanoseconds.subtractingReportingOverflow(correction)
        if overflow {
            correctedTime = correction >= 0 ? Int64.min : Int64.max
        } else {
            correctedTime = value
        }
        return PerformanceEvent(
            id: event.id,
            sessionID: event.sessionID,
            source: event.source,
            voice: event.voice,
            hostTime: event.hostTime,
            sessionTimeNanoseconds: correctedTime,
            velocity: event.velocity,
            confidence: event.confidence,
            rawMetadata: event.rawMetadata,
            audioFeatures: event.audioFeatures
        )
    }

    private func absoluteDifference(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        if lhs >= rhs { return UInt64(bitPattern: lhs &- rhs) }
        return UInt64(bitPattern: rhs &- lhs)
    }
}

private enum Transition: Equatable {
    case matchedCorrect
    case matchedWrongVoice
    case missed
    case extra

    var rank: Int {
        switch self {
        case .matchedCorrect: 0
        case .matchedWrongVoice: 1
        case .missed: 2
        case .extra: 3
        }
    }
}
