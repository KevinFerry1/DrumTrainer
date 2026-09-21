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

    func testMIDISynchronizationPreservesRawPadSeparationDespiteVoiceCorrections() throws {
        let groupID = UUID()
        let expected = [
            ExpectedEvent(
                measure: 1, beat: 1, subdivision: 0,
                sessionTimeNanoseconds: 1_000_000_000,
                voice: .snare,
                simultaneousGroupID: groupID
            ),
            ExpectedEvent(
                measure: 1, beat: 1, subdivision: 0,
                sessionTimeNanoseconds: 1_000_000_000,
                voice: .openHiHat,
                simultaneousGroupID: groupID
            )
        ]
        let actual = [
            event(voice: .snare, milliseconds: 1_000, velocity: 0.7),
            event(voice: .openHiHat, milliseconds: 1_030, velocity: 0.7)
        ]
        let matcher = EventMatcher(voiceTimingCompensationNanoseconds: [
            EventTimingCompensationKey(source: .midi, voice: .snare): 0,
            EventTimingCompensationKey(source: .midi, voice: .openHiHat): 30_000_000
        ])
        let matches = matcher.match(expected: expected, actual: actual)
        XCTAssertTrue(matches.allSatisfy { $0.classification == .correct })
        XCTAssertEqual(Set(matches.compactMap(\.actualTimeNanoseconds)), [1_000_000_000])

        let synchronization = try XCTUnwrap(calculator.calculate(
            from: matches,
            expectedEvents: expected,
            actualEvents: actual
        ).limbSynchronization)

        XCTAssertEqual(synchronization.averageSpreadMilliseconds, 30)
        let snare = try XCTUnwrap(synchronization.voiceOffsets.first { $0.voice == .snare })
        let hiHat = try XCTUnwrap(synchronization.voiceOffsets.first { $0.voice == .openHiHat })
        XCTAssertEqual(snare.meanOffsetFromGroupCenterMilliseconds, -15)
        XCTAssertEqual(hiHat.meanOffsetFromGroupCenterMilliseconds, 15)
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

    func testAccentEvaluationUsesMIDIVelocityAndAffectsCleanRunQualification() throws {
        let threshold = 100.0 / 127.0
        let expected = [
            ExpectedEvent(
                measure: 1,
                beat: 1,
                subdivision: 0,
                sessionTimeNanoseconds: 100_000_000,
                voice: .closedHiHat,
                minimumAccentVelocity: threshold
            ),
            ExpectedEvent(
                measure: 1,
                beat: 2,
                subdivision: 0,
                sessionTimeNanoseconds: 600_000_000,
                voice: .snare,
                minimumAccentVelocity: threshold
            )
        ]
        let actual = [
            event(voice: .closedHiHat, milliseconds: 105, velocity: 112.0 / 127.0),
            event(voice: .snare, milliseconds: 605, velocity: 82.0 / 127.0)
        ]
        let pattern = PracticePattern(
            name: "Accent fixture",
            bpm: 120,
            beatsPerMeasure: 4,
            measures: 1,
            expectedEvents: expected
        )
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 2_000_000_000
        )
        actual.forEach { recording.record($0) }
        let outcome = recording.finish()
        let evaluation = try XCTUnwrap(outcome.accentEvaluation)

        XCTAssertEqual(outcome.metrics.recall, 1)
        XCTAssertEqual(evaluation.metrics.expectedCount, 2)
        XCTAssertEqual(evaluation.metrics.achievedCount, 1)
        XCTAssertEqual(evaluation.metrics.belowThresholdCount, 1)
        XCTAssertEqual(evaluation.metrics.accuracy, 0.5)
        XCTAssertEqual(evaluation.results.map(\.classification), [.achieved, .belowThreshold])
        XCTAssertFalse(
            PracticeSessionSummary(outcome: outcome, exerciseKind: .custom).isClean
        )
    }

    func testAccentEvaluationRequiresLocalSameVoiceContrast() throws {
        let contrast = 18.0 / 127.0
        let expected = [
            ExpectedEvent(
                measure: 1,
                beat: 1,
                subdivision: 0,
                sessionTimeNanoseconds: 100_000_000,
                voice: .closedHiHat
            ),
            ExpectedEvent(
                measure: 1,
                beat: 1,
                subdivision: 1,
                sessionTimeNanoseconds: 300_000_000,
                voice: .snare
            ),
            ExpectedEvent(
                measure: 1,
                beat: 2,
                subdivision: 0,
                sessionTimeNanoseconds: 500_000_000,
                voice: .closedHiHat,
                minimumAccentContrast: contrast
            ),
            ExpectedEvent(
                measure: 1,
                beat: 2,
                subdivision: 1,
                sessionTimeNanoseconds: 700_000_000,
                voice: .closedHiHat,
                minimumAccentContrast: contrast
            )
        ]
        let actual = [
            event(voice: .closedHiHat, milliseconds: 105, velocity: 105.0 / 127.0),
            event(voice: .snare, milliseconds: 305, velocity: 127.0 / 127.0),
            event(voice: .closedHiHat, milliseconds: 505, velocity: 110.0 / 127.0),
            event(voice: .closedHiHat, milliseconds: 705, velocity: 127.0 / 127.0)
        ]
        let matches = EventMatcher().match(expected: expected, actual: actual)
        let evaluation = try XCTUnwrap(AccentEvaluator().evaluate(
            expectedEvents: expected,
            actualEvents: actual,
            matchResults: matches
        ))

        XCTAssertEqual(evaluation.results.map(\.classification), [.insufficientContrast, .achieved])
        XCTAssertEqual(evaluation.results.map(\.baselineVelocity), [105.0 / 127.0, 105.0 / 127.0])
        XCTAssertEqual(
            try XCTUnwrap(evaluation.results.first?.requiredContrast),
            21.0 / 127.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(evaluation.metrics.achievedCount, 1)
        XCTAssertEqual(evaluation.metrics.belowThresholdCount, 1)
        XCTAssertEqual(evaluation.metrics.accuracy, 0.5)
    }

    func testAccentWithoutSameVoiceBaselineUsesOptionalFloorFallback() throws {
        let contrast = 18.0 / 127.0
        let expected = [
            ExpectedEvent(
                measure: 1,
                beat: 1,
                subdivision: 0,
                sessionTimeNanoseconds: 100_000_000,
                voice: .closedHiHat,
                minimumAccentVelocity: 100.0 / 127.0,
                minimumAccentContrast: contrast
            ),
            ExpectedEvent(
                measure: 1,
                beat: 2,
                subdivision: 0,
                sessionTimeNanoseconds: 600_000_000,
                voice: .snare,
                minimumAccentContrast: contrast
            )
        ]
        let actual = [
            event(voice: .closedHiHat, milliseconds: 105, velocity: 108.0 / 127.0),
            event(voice: .snare, milliseconds: 605, velocity: 127.0 / 127.0)
        ]
        let matches = EventMatcher().match(expected: expected, actual: actual)
        let evaluation = try XCTUnwrap(AccentEvaluator().evaluate(
            expectedEvents: expected,
            actualEvents: actual,
            matchResults: matches
        ))

        XCTAssertEqual(evaluation.results.map(\.classification), [.achieved, .baselineUnavailable])
        XCTAssertTrue(evaluation.results[0].didUseMinimumOnly)
        XCTAssertEqual(evaluation.metrics.notEvaluatedCount, 1)
    }

    func testGhostContrastUsesNormalSameVoiceHitsAndExactBoundary() throws {
        let expected = [
            dynamicNote(0),
            dynamicNote(1, voice: .closedHiHat),
            dynamicNote(2, accent: true),
            dynamicNote(3, ghost: true),
            dynamicNote(4, ghost: true)
        ]
        let actual = [
            event(voice: .snare, milliseconds: 100, velocity: 80.0 / 127),
            event(voice: .closedHiHat, milliseconds: 600, velocity: 20.0 / 127),
            event(voice: .snare, milliseconds: 1100, velocity: 120.0 / 127),
            event(voice: .snare, milliseconds: 1600, velocity: 62.0 / 127),
            event(voice: .snare, milliseconds: 2100, velocity: 63.0 / 127)
        ]
        let evaluation = try XCTUnwrap(GhostEvaluator().evaluate(
            expectedEvents: expected, actualEvents: actual,
            matchResults: EventMatcher().match(expected: expected, actual: actual)
        ))
        XCTAssertEqual(evaluation.results.map(\.classification), [.achieved, .insufficientContrast])
        XCTAssertEqual(try XCTUnwrap(evaluation.results[0].baselineVelocity), 80.0 / 127, accuracy: 1e-10)
        XCTAssertEqual(evaluation.metrics.accuracy, 0.5)
        let accents = try XCTUnwrap(AccentEvaluator().evaluate(
            expectedEvents: expected, actualEvents: actual,
            matchResults: EventMatcher().match(expected: expected, actual: actual)
        ))
        XCTAssertEqual(try XCTUnwrap(accents.results[0].baselineVelocity), 80.0 / 127, accuracy: 1e-10)
    }

    func testGhostPercentageCeilingAndUnavailableEvidence() throws {
        let expected = [
            dynamicNote(0),
            dynamicNote(1, ghost: true),
            dynamicNote(2, ghost: true, ceiling: 50),
            dynamicNote(3, ghost: true),
            dynamicNote(4, ghost: true)
        ]
        let actual = [
            event(voice: .snare, milliseconds: 100, velocity: 100.0 / 127),
            event(voice: .snare, milliseconds: 600, velocity: 80.0 / 127),
            event(voice: .snare, milliseconds: 1100, velocity: 51.0 / 127),
            event(voice: .snare, milliseconds: 1600)
        ]
        let evaluation = try XCTUnwrap(GhostEvaluator().evaluate(
            expectedEvents: expected, actualEvents: actual,
            matchResults: EventMatcher().match(expected: expected, actual: actual)
        ))
        XCTAssertEqual(evaluation.results.map(\.classification),
                       [.achieved, .aboveThreshold, .velocityUnavailable, .missed])
        XCTAssertEqual(try XCTUnwrap(evaluation.results[0].requiredContrast), 20.0 / 127, accuracy: 1e-10)
        XCTAssertEqual(evaluation.metrics.notEvaluatedCount, 2)
        XCTAssertFalse(evaluation.metrics.passesCleanThreshold)
    }

    func testGhostNoBaselineFallbackAndImpossibleSoftnessTarget() throws {
        let expected = [
            dynamicNote(0, ghost: true, ceiling: 50),
            dynamicNote(1, ghost: true)
        ]
        let actual = [
            event(voice: .snare, milliseconds: 100, velocity: 50.0 / 127),
            event(voice: .snare, milliseconds: 600, velocity: 30.0 / 127)
        ]
        let evaluation = try XCTUnwrap(GhostEvaluator().evaluate(
            expectedEvents: expected, actualEvents: actual,
            matchResults: EventMatcher().match(expected: expected, actual: actual)
        ))
        XCTAssertEqual(evaluation.results.map(\.classification), [.achieved, .baselineUnavailable])
        XCTAssertTrue(evaluation.results[0].didUseMaximumOnly)
        let softExpected = [dynamicNote(0), dynamicNote(1, ghost: true)]
        let softActual = [
            event(voice: .snare, milliseconds: 100, velocity: 10.0 / 127),
            event(voice: .snare, milliseconds: 600, velocity: 1.0 / 127)
        ]
        let impossible = try XCTUnwrap(GhostEvaluator().evaluate(
            expectedEvents: softExpected, actualEvents: softActual,
            matchResults: EventMatcher().match(expected: softExpected, actual: softActual)
        ))
        XCTAssertEqual(impossible.results[0].classification, .insufficientContrast)
    }

    func testDynamicAccuracyIsReportedPerVoiceAndOmitsInapplicableVoices() throws {
        let accentFloor = 100.0 / 127.0
        let ghostCeiling = 60.0 / 127.0
        let expected = [
            ExpectedEvent(
                measure: 1, beat: 1, subdivision: 0,
                sessionTimeNanoseconds: 100_000_000,
                voice: .snare,
                minimumAccentVelocity: accentFloor
            ),
            ExpectedEvent(
                measure: 1, beat: 2, subdivision: 0,
                sessionTimeNanoseconds: 600_000_000,
                voice: .snare,
                minimumAccentVelocity: accentFloor
            ),
            ExpectedEvent(
                measure: 1, beat: 3, subdivision: 0,
                sessionTimeNanoseconds: 1_100_000_000,
                voice: .openHiHat,
                minimumAccentVelocity: accentFloor
            ),
            ExpectedEvent(
                measure: 1, beat: 4, subdivision: 0,
                sessionTimeNanoseconds: 1_600_000_000,
                voice: .snare,
                maximumGhostVelocity: ghostCeiling
            ),
            ExpectedEvent(
                measure: 2, beat: 1, subdivision: 0,
                sessionTimeNanoseconds: 2_100_000_000,
                voice: .openHiHat,
                maximumGhostVelocity: ghostCeiling
            ),
            ExpectedEvent(
                measure: 2, beat: 2, subdivision: 0,
                sessionTimeNanoseconds: 2_600_000_000,
                voice: .openHiHat,
                maximumGhostVelocity: ghostCeiling
            )
        ]
        let actual = [
            event(voice: .snare, milliseconds: 100, velocity: 110.0 / 127.0),
            event(voice: .snare, milliseconds: 600, velocity: 80.0 / 127.0),
            event(voice: .openHiHat, milliseconds: 1_100, velocity: 115.0 / 127.0),
            event(voice: .snare, milliseconds: 1_600, velocity: 50.0 / 127.0),
            event(voice: .openHiHat, milliseconds: 2_100, velocity: 55.0 / 127.0),
            event(voice: .openHiHat, milliseconds: 2_600, velocity: 70.0 / 127.0)
        ]
        let matches = EventMatcher().match(expected: expected, actual: actual)
        let accents = try XCTUnwrap(AccentEvaluator().evaluate(
            expectedEvents: expected,
            actualEvents: actual,
            matchResults: matches
        ))
        let ghosts = try XCTUnwrap(GhostEvaluator().evaluate(
            expectedEvents: expected,
            actualEvents: actual,
            matchResults: matches
        ))

        XCTAssertEqual(accents.voiceAccuracy(for: .snare), DynamicVoiceAccuracy(expectedCount: 2, achievedCount: 1))
        XCTAssertEqual(accents.voiceAccuracy(for: .openHiHat), DynamicVoiceAccuracy(expectedCount: 1, achievedCount: 1))
        XCTAssertNil(accents.voiceAccuracy(for: .kick))
        XCTAssertEqual(ghosts.voiceAccuracy(for: .snare), DynamicVoiceAccuracy(expectedCount: 1, achievedCount: 1))
        XCTAssertEqual(ghosts.voiceAccuracy(for: .openHiHat), DynamicVoiceAccuracy(expectedCount: 2, achievedCount: 1))
        XCTAssertNil(ghosts.voiceAccuracy(for: .kick))
    }

    func testStableSharedTimingBiasUsesLatencyAwareGrooveGrade() throws {
        let offsets: [Int64] = [48, 50, 52, 49, 51, 50, 47, 53, 49, 51, 50, 52]
        let expected = offsets.indices.map { index in
            ExpectedEvent(
                measure: index / 4 + 1,
                beat: index % 4 + 1,
                subdivision: 0,
                sessionTimeNanoseconds: Int64(100 + index * 500) * 1_000_000,
                voice: .snare
            )
        }
        let pattern = PracticePattern(
            name: "Stable latency fixture",
            bpm: 120,
            beatsPerMeasure: 4,
            measures: 3,
            expectedEvents: expected
        )
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 6_000_000_000
        )
        for (event, offset) in zip(expected, offsets) {
            recording.record(self.event(
                voice: .snare,
                milliseconds: event.sessionTimeNanoseconds / 1_000_000 + offset
            ))
        }

        let outcome = recording.finish()
        let evaluation = try XCTUnwrap(outcome.stableTimingBiasEvaluation)
        let summary = PracticeSessionSummary(outcome: outcome, exerciseKind: .builtIn)

        XCTAssertEqual(evaluation.biasMilliseconds, 50, accuracy: 0.001)
        XCTAssertEqual(evaluation.rawMedianAbsoluteErrorMilliseconds, 50, accuracy: 0.001)
        XCTAssertEqual(evaluation.adjustedMedianAbsoluteErrorMilliseconds, 1, accuracy: 0.001)
        XCTAssertEqual(summary.latencyAdjustedMedianErrorMilliseconds, 1)
        XCTAssertTrue(summary.isClean)
        let coaching = PracticeResultCoach().summarize(outcome)
        XCTAssertTrue(coaching.overview.contains("shared +50.0 ms raw offset"))
        XCTAssertTrue(coaching.nextStep.contains("Re-run hit timing alignment"))
    }

    func testUnstableOrSmallTimingOffsetsDoNotReceiveLatencyAdjustment() {
        let unstable = [30.0, 70, 31, 69, 32, 68, 30, 70].map {
            result(.correct, offset: $0)
        }
        let small = Array(repeating: 20.0, count: 8).map {
            result(.correct, offset: $0)
        }

        XCTAssertNil(StableTimingBiasEvaluator().evaluate(unstable))
        XCTAssertNil(StableTimingBiasEvaluator().evaluate(small))
    }

    func testPracticeCoachExplainsSoftAccentsAndMeasuredSnareHatSeparation() {
        let accentFloor = 100.0 / 127.0
        var expected: [ExpectedEvent] = []
        var actual: [PerformanceEvent] = []
        for index in 0..<8 {
            let time = Int64(100 + index * 500)
            let groupID = UUID()
            expected.append(ExpectedEvent(
                measure: index / 4 + 1,
                beat: index % 4 + 1,
                subdivision: 0,
                sessionTimeNanoseconds: time * 1_000_000,
                voice: .snare,
                minimumAccentVelocity: accentFloor,
                simultaneousGroupID: groupID
            ))
            expected.append(ExpectedEvent(
                measure: index / 4 + 1,
                beat: index % 4 + 1,
                subdivision: 0,
                sessionTimeNanoseconds: time * 1_000_000,
                voice: .openHiHat,
                simultaneousGroupID: groupID
            ))
            actual.append(event(
                voice: .openHiHat,
                milliseconds: time,
                velocity: 110.0 / 127.0
            ))
            actual.append(event(
                voice: .snare,
                milliseconds: time + 30,
                velocity: 60.0 / 127.0
            ))
        }
        let pattern = PracticePattern(
            name: "Snare and hat fixture",
            bpm: 120,
            beatsPerMeasure: 4,
            measures: 2,
            expectedEvents: expected
        )
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 4_000_000_000
        )
        actual.forEach { recording.record($0) }

        let coaching = PracticeResultCoach().summarize(recording.finish())

        XCTAssertTrue(coaching.overview.contains("accents were often too soft"))
        XCTAssertTrue(coaching.nextStep.contains("land the snare and open hi-hat together"))
        XCTAssertTrue(coaching.nextStep.contains("behind the hat"))
    }

    private func dynamicNote(
        _ index: Int, voice: DrumVoice = .snare, accent: Bool = false,
        ghost: Bool = false, ceiling: Double? = nil
    ) -> ExpectedEvent {
        ExpectedEvent(
            measure: 1, beat: index + 1, subdivision: 0,
            sessionTimeNanoseconds: Int64(100 + index * 500) * 1_000_000,
            voice: voice,
            minimumAccentContrast: accent ? 18.0 / 127 : nil,
            maximumGhostVelocity: ceiling.map { $0 / 127 },
            minimumGhostContrast: ghost ? 18.0 / 127 : nil
        )
    }

    private func event(
        voice: DrumVoice,
        milliseconds: Int64,
        velocity: Double? = nil
    ) -> PerformanceEvent {
        PerformanceEvent(
            source: velocity == nil && voice == .kick ? .microphone : .midi,
            voice: voice,
            hostTime: UInt64(milliseconds * 1_000_000),
            sessionTimeNanoseconds: milliseconds * 1_000_000,
            velocity: velocity,
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
