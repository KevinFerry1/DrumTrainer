import XCTest
@testable import DrumTrainer

final class ScoringMetricsTests: XCTestCase {
    private let calculator = ScoringMetricsCalculator()

    func testCalculatesAccuracyTimingAndStreakMetrics() {
        let results = [
            result(.correct, expectedTime: 0, actualTime: -10, offset: -10),
            result(.wrongVoice, expectedTime: 100, actualTime: 105, offset: 5),
            result(.correct, expectedTime: 200, actualTime: 230, offset: 30),
            result(.missed, expectedTime: 300),
            result(.extra, actualTime: 400)
        ]

        let metrics = calculator.calculate(from: results)

        XCTAssertEqual(metrics.totalExpected, 4)
        XCTAssertEqual(metrics.totalPlayed, 4)
        XCTAssertEqual(metrics.correctCount, 2)
        XCTAssertEqual(metrics.wrongVoiceCount, 1)
        XCTAssertEqual(metrics.missedCount, 1)
        XCTAssertEqual(metrics.extraCount, 1)
        XCTAssertEqual(metrics.recall, 0.5)
        XCTAssertEqual(metrics.precision, 0.5)
        XCTAssertEqual(metrics.meanSignedOffsetMilliseconds, 10)
        XCTAssertEqual(metrics.meanAbsoluteErrorMilliseconds, 20)
        XCTAssertEqual(metrics.medianAbsoluteErrorMilliseconds, 20)
        XCTAssertEqual(metrics.timingStandardDeviationMilliseconds, 20)
        XCTAssertEqual(metrics.earlyCount, 1)
        XCTAssertEqual(metrics.lateCount, 1)
        XCTAssertEqual(metrics.longestCleanStreak, 1)
    }

    func testTimingBandsUseDocumentedThresholds() {
        XCTAssertEqual(calculator.timingBand(for: result(.correct, offset: 20)), .tight)
        XCTAssertEqual(calculator.timingBand(for: result(.correct, offset: -40)), .good)
        XCTAssertEqual(calculator.timingBand(for: result(.correct, offset: 70)), .acceptable)
        XCTAssertEqual(calculator.timingBand(for: result(.correct, offset: 71)), .loose)
        XCTAssertEqual(calculator.timingBand(for: result(.missed)), .unmatched)
    }

    func testEmptyResultsProduceDefinedZeroRatesWithoutFakeTimingData() {
        let metrics = calculator.calculate(from: [])

        XCTAssertEqual(metrics.recall, 0)
        XCTAssertEqual(metrics.precision, 0)
        XCTAssertNil(metrics.meanSignedOffsetMilliseconds)
        XCTAssertNil(metrics.meanAbsoluteErrorMilliseconds)
        XCTAssertNil(metrics.medianAbsoluteErrorMilliseconds)
        XCTAssertNil(metrics.timingStandardDeviationMilliseconds)
        XCTAssertTrue(metrics.perVoice.isEmpty)
        XCTAssertNil(metrics.limbSynchronization)
    }

    func testCalculatesPerVoiceAndLimbSynchronizationMetricsFromRawEvidence() throws {
        let groupID = UUID()
        let kickOne = ExpectedEvent(
            measure: 1,
            beat: 1,
            subdivision: 0,
            sessionTimeNanoseconds: 100_000_000,
            voice: .kick,
            simultaneousGroupID: groupID
        )
        let snare = ExpectedEvent(
            measure: 1,
            beat: 1,
            subdivision: 0,
            sessionTimeNanoseconds: 100_000_000,
            voice: .snare,
            simultaneousGroupID: groupID
        )
        let kickTwo = ExpectedEvent(
            measure: 1,
            beat: 1,
            subdivision: 1,
            sessionTimeNanoseconds: 200_000_000,
            voice: .kick
        )
        let actual = [
            event(voice: .kick, milliseconds: 110),
            event(voice: .snare, milliseconds: 125),
            event(voice: .kick, milliseconds: 190),
            event(voice: .ride, milliseconds: 350)
        ]
        let expected = [kickOne, snare, kickTwo]
        let matches = EventMatcher().match(expected: expected, actual: actual)

        let metrics = calculator.calculate(
            from: matches,
            expectedEvents: expected,
            actualEvents: actual
        )

        let kick = try XCTUnwrap(metrics.perVoice.first { $0.voice == .kick })
        XCTAssertEqual(kick.totalExpected, 2)
        XCTAssertEqual(kick.totalPlayed, 2)
        XCTAssertEqual(kick.correctCount, 2)
        XCTAssertEqual(kick.recall, 1)
        XCTAssertEqual(kick.precision, 1)
        XCTAssertEqual(kick.meanSignedOffsetMilliseconds, 0)
        XCTAssertEqual(kick.medianAbsoluteErrorMilliseconds, 10)

        let ride = try XCTUnwrap(metrics.perVoice.first { $0.voice == .ride })
        XCTAssertEqual(ride.totalExpected, 0)
        XCTAssertEqual(ride.totalPlayed, 1)
        XCTAssertEqual(ride.extraCount, 1)

        let synchronization = try XCTUnwrap(metrics.limbSynchronization)
        XCTAssertEqual(synchronization.eligibleGroupCount, 1)
        XCTAssertEqual(synchronization.completedGroupCount, 1)
        XCTAssertEqual(synchronization.averageSpreadMilliseconds, 15)
        XCTAssertEqual(synchronization.medianSpreadMilliseconds, 15)
        XCTAssertEqual(synchronization.worstSpreadMilliseconds, 15)
        let kickOffset = try XCTUnwrap(synchronization.voiceOffsets.first { $0.voice == .kick })
        let snareOffset = try XCTUnwrap(synchronization.voiceOffsets.first { $0.voice == .snare })
        XCTAssertEqual(kickOffset.meanOffsetFromGroupCenterMilliseconds, -7.5)
        XCTAssertEqual(snareOffset.meanOffsetFromGroupCenterMilliseconds, 7.5)
    }

    func testIncompleteSimultaneousGroupsAreReportedButExcludedFromSpread() throws {
        let groupID = UUID()
        let expected = [
            ExpectedEvent(
                measure: 1,
                beat: 1,
                subdivision: 0,
                sessionTimeNanoseconds: 100_000_000,
                voice: .kick,
                simultaneousGroupID: groupID
            ),
            ExpectedEvent(
                measure: 1,
                beat: 1,
                subdivision: 0,
                sessionTimeNanoseconds: 100_000_000,
                voice: .snare,
                simultaneousGroupID: groupID
            )
        ]
        let actual = [event(voice: .kick, milliseconds: 105)]
        let matches = EventMatcher().match(expected: expected, actual: actual)

        let synchronization = try XCTUnwrap(calculator.calculate(
            from: matches,
            expectedEvents: expected,
            actualEvents: actual
        ).limbSynchronization)

        XCTAssertEqual(synchronization.eligibleGroupCount, 1)
        XCTAssertEqual(synchronization.completedGroupCount, 0)
        XCTAssertNil(synchronization.averageSpreadMilliseconds)
        XCTAssertNil(synchronization.medianSpreadMilliseconds)
        XCTAssertNil(synchronization.worstSpreadMilliseconds)
        XCTAssertTrue(synchronization.voiceOffsets.isEmpty)
    }

    func testWrongVoiceIsAttributedToPlayedVoiceWhileExpectedVoiceRecordsError() throws {
        let expected = [ExpectedEvent(
            measure: 1,
            beat: 1,
            subdivision: 0,
            sessionTimeNanoseconds: 100_000_000,
            voice: .snare
        )]
        let actual = [event(voice: .highTom, milliseconds: 105)]
        let matches = EventMatcher().match(expected: expected, actual: actual)

        let metrics = calculator.calculate(
            from: matches,
            expectedEvents: expected,
            actualEvents: actual
        )
        let snare = try XCTUnwrap(metrics.perVoice.first { $0.voice == .snare })
        let tom = try XCTUnwrap(metrics.perVoice.first { $0.voice == .highTom })

        XCTAssertEqual(snare.totalExpected, 1)
        XCTAssertEqual(snare.totalPlayed, 0)
        XCTAssertEqual(snare.wrongVoiceCount, 1)
        XCTAssertEqual(tom.totalExpected, 0)
        XCTAssertEqual(tom.totalPlayed, 1)
        XCTAssertEqual(tom.extraCount, 0)
    }

    private func event(voice: DrumVoice, milliseconds: Int64) -> PerformanceEvent {
        PerformanceEvent(
            source: voice == .kick ? .microphone : .midi,
            voice: voice,
            hostTime: UInt64(milliseconds * 1_000_000),
            sessionTimeNanoseconds: milliseconds * 1_000_000,
            rawMetadata: .simulated(label: "metrics fixture")
        )
    }

    private func result(
        _ classification: MatchClassification,
        expectedTime: Int64? = 0,
        actualTime: Int64? = 0,
        offset: Double? = nil
    ) -> MatchResult {
        MatchResult(
            expectedEventID: classification == .extra ? nil : UUID(),
            actualEventID: classification == .missed ? nil : UUID(),
            classification: classification,
            expectedTimeNanoseconds: expectedTime.map { $0 * 1_000_000 },
            actualTimeNanoseconds: actualTime.map { $0 * 1_000_000 },
            signedOffsetMilliseconds: offset
        )
    }
}
