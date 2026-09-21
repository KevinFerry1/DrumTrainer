import XCTest
@testable import DrumTrainer

final class EventMatcherTests: XCTestCase {
    private let matcher = EventMatcher()

    func testMatchesDenseSixteenthsOneToOneWithSignedOffsets() {
        let expected = [0, 125, 250, 375].map { expectedEvent(milliseconds: $0) }
        let actual = [10, 110, 270, 370].map { actualEvent(milliseconds: $0) }

        let results = matcher.match(expected: expected, actual: actual)

        XCTAssertEqual(results.map(\.classification), [.correct, .correct, .correct, .correct])
        XCTAssertEqual(results.compactMap(\.signedOffsetMilliseconds), [10, -15, 20, -5])
        XCTAssertEqual(Set(results.compactMap(\.actualEventID)).count, 4)
    }

    func testOneActualCannotSatisfyTwoExpectedNotes() {
        let results = matcher.match(
            expected: [expectedEvent(milliseconds: 0), expectedEvent(milliseconds: 100)],
            actual: [actualEvent(milliseconds: 60)]
        )

        XCTAssertEqual(results.count { $0.classification == .correct }, 1)
        XCTAssertEqual(results.count { $0.classification == .missed }, 1)
    }

    func testBoundaryToleranceIsInclusiveAndBeyondBoundaryIsUnmatched() {
        let onBoundary = matcher.match(
            expected: [expectedEvent(milliseconds: 1_000, toleranceMilliseconds: 100)],
            actual: [actualEvent(milliseconds: 1_100)]
        )
        XCTAssertEqual(onBoundary.map(\.classification), [.correct])

        let outside = matcher.match(
            expected: [expectedEvent(milliseconds: 1_000, toleranceMilliseconds: 100)],
            actual: [actualEvent(milliseconds: 1_101)]
        )
        XCTAssertEqual(Set(outside.map(\.classification)), [.missed, .extra])
    }

    func testNearbyIncompatibleHitIsOneWrongVoiceInsteadOfDoublePenalty() {
        let results = matcher.match(
            expected: [expectedEvent(milliseconds: 500, voice: .kick)],
            actual: [actualEvent(milliseconds: 515, voice: .snare)]
        )

        XCTAssertEqual(results.map(\.classification), [.wrongVoice])
        XCTAssertEqual(results[0].signedOffsetMilliseconds, 15)
    }

    func testAllowedVoiceVariantCanMatch() {
        let expected = ExpectedEvent(
            measure: 1,
            beat: 1,
            subdivision: 0,
            sessionTimeNanoseconds: 0,
            voice: .ride,
            allowedVoices: [.rideBell]
        )

        XCTAssertEqual(
            matcher.match(expected: [expected], actual: [actualEvent(milliseconds: 5, voice: .rideBell)])
                .map(\.classification),
            [.correct]
        )
    }

    func testEqualDistanceCandidatesAreMarkedAmbiguous() {
        let results = matcher.match(
            expected: [expectedEvent(milliseconds: 1_000)],
            actual: [actualEvent(milliseconds: 990), actualEvent(milliseconds: 1_010)]
        )

        XCTAssertEqual(results.count { $0.classification == .ambiguous }, 1)
        XCTAssertEqual(results.count { $0.classification == .extra }, 1)
    }

    func testReferenceMetronomeEventsAreNotScoredAsPlayedHits() {
        let reference = PerformanceEvent(
            source: .metronome,
            voice: .metronome,
            hostTime: 0,
            sessionTimeNanoseconds: 0,
            rawMetadata: .metronome(beat: 1, subdivision: 0)
        )

        let results = matcher.match(expected: [expectedEvent(milliseconds: 0)], actual: [reference])
        XCTAssertEqual(results.map(\.classification), [.missed])
    }

    func testMatchesSixtySecondsOfDenseHighTempoSixteenths() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 240,
            subdivision: .sixteenths,
            measures: 60
        ))
        let actual = pattern.expectedEvents.map { expected in
            actualEvent(nanoseconds: expected.sessionTimeNanoseconds + 3_000_000)
        }

        let results = matcher.match(expected: pattern.expectedEvents, actual: actual)

        XCTAssertEqual(results.count, 960)
        XCTAssertTrue(results.allSatisfy { $0.classification == .correct })
    }

    func testSourceTimingCompensationIsAppliedWithoutChangingRawEvent() {
        let expected = expectedEvent(milliseconds: 1_000, voice: .snare, toleranceMilliseconds: 30)
        let actual = actualEvent(milliseconds: 1_050, voice: .snare)
        let compensated = EventMatcher(sourceTimingCompensationNanoseconds: [.midi: 50_000_000])

        let uncompensatedResults = matcher.match(expected: [expected], actual: [actual])
        let compensatedResults = compensated.match(expected: [expected], actual: [actual])

        XCTAssertEqual(Set(uncompensatedResults.map(\.classification)), [.missed, .extra])
        XCTAssertEqual(compensatedResults.map(\.classification), [.correct])
        XCTAssertEqual(compensatedResults.first?.signedOffsetMilliseconds, 0)
        XCTAssertEqual(actual.sessionTimeNanoseconds, 1_050_000_000)
    }

    func testVoiceTimingCompensationAppliesIndependentOffsetsToEachDrum() {
        let expected = [
            expectedEvent(milliseconds: 1_000, voice: .snare, toleranceMilliseconds: 10),
            expectedEvent(milliseconds: 1_500, voice: .openHiHat, toleranceMilliseconds: 10)
        ]
        let actual = [
            actualEvent(milliseconds: 1_050, voice: .snare),
            actualEvent(milliseconds: 1_520, voice: .openHiHat)
        ]
        let compensated = EventMatcher(voiceTimingCompensationNanoseconds: [
            EventTimingCompensationKey(source: .midi, voice: .snare): 50_000_000,
            EventTimingCompensationKey(source: .midi, voice: .openHiHat): 20_000_000
        ])

        let results = compensated.match(expected: expected, actual: actual)

        XCTAssertEqual(results.map(\.classification), [.correct, .correct])
        XCTAssertEqual(results.compactMap(\.signedOffsetMilliseconds), [0, 0])
        XCTAssertEqual(actual.map(\.sessionTimeNanoseconds), [1_050_000_000, 1_520_000_000])
    }

    func testNearSimultaneousChordMatchesByVoiceDespiteArrivalOrder() {
        let expected = [
            expectedEvent(milliseconds: 1_000, voice: .kick),
            expectedEvent(milliseconds: 1_000, voice: .openHiHat),
            expectedEvent(milliseconds: 1_000, voice: .snare)
        ]
        let actual = [
            actualEvent(milliseconds: 995, voice: .snare),
            actualEvent(milliseconds: 1_004, voice: .openHiHat),
            actualEvent(milliseconds: 1_012, voice: .kick)
        ]

        let results = matcher.match(expected: expected, actual: actual)

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0.classification == .correct })
    }

    private func expectedEvent(
        milliseconds: Int,
        voice: DrumVoice = .kick,
        toleranceMilliseconds: Int = 100
    ) -> ExpectedEvent {
        ExpectedEvent(
            measure: 1,
            beat: 1,
            subdivision: 0,
            sessionTimeNanoseconds: Int64(milliseconds) * 1_000_000,
            voice: voice,
            matchingToleranceNanoseconds: Int64(toleranceMilliseconds) * 1_000_000
        )
    }

    private func actualEvent(milliseconds: Int, voice: DrumVoice = .kick) -> PerformanceEvent {
        actualEvent(nanoseconds: Int64(milliseconds) * 1_000_000, voice: voice)
    }

    private func actualEvent(nanoseconds: Int64, voice: DrumVoice = .kick) -> PerformanceEvent {
        PerformanceEvent(
            source: voice == .kick ? .microphone : .midi,
            voice: voice,
            hostTime: UInt64(max(0, nanoseconds)),
            sessionTimeNanoseconds: nanoseconds,
            rawMetadata: .simulated(label: "matcher fixture")
        )
    }
}
