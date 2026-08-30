import XCTest
@testable import DrumTrainer

final class KickPatternGeneratorTests: XCTestCase {
    func testGeneratesOneMeasureOfSixteenthsAt120BPM() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            subdivision: .sixteenths
        ))

        XCTAssertEqual(pattern.expectedEvents.count, 16)
        XCTAssertEqual(pattern.expectedEvents.map(\.sessionTimeNanoseconds), [
            0, 125_000_000, 250_000_000, 375_000_000,
            500_000_000, 625_000_000, 750_000_000, 875_000_000,
            1_000_000_000, 1_125_000_000, 1_250_000_000, 1_375_000_000,
            1_500_000_000, 1_625_000_000, 1_750_000_000, 1_875_000_000
        ])
        XCTAssertEqual(pattern.expectedEvents[4].beat, 2)
        XCTAssertEqual(pattern.expectedEvents[4].subdivision, 0)
        XCTAssertTrue(pattern.expectedEvents.allSatisfy { $0.voice == .kick })
        XCTAssertEqual(pattern.durationNanoseconds, 2_000_000_000)
        XCTAssertEqual(pattern.measureStartOffsetsNanoseconds, [0, 2_000_000_000])
        XCTAssertEqual(pattern.referenceBeats?.map(\.offsetNanoseconds), [
            0, 500_000_000, 1_000_000_000, 1_500_000_000
        ])
        XCTAssertEqual(pattern.referenceBeats?.map(\.beat), [1, 2, 3, 4])
        XCTAssertEqual(pattern.referenceBeats?.map(\.isAccent), [true, false, false, false])
    }

    func testTripletsUseMusicalGridWithoutCumulativeRoundingDrift() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            subdivision: .triplets,
            measures: 2
        ))

        XCTAssertEqual(pattern.expectedEvents.count, 24)
        XCTAssertEqual(pattern.expectedEvents[1].sessionTimeNanoseconds, 166_666_667)
        XCTAssertEqual(pattern.expectedEvents[3].sessionTimeNanoseconds, 500_000_000)
        XCTAssertEqual(pattern.expectedEvents[12].sessionTimeNanoseconds, 2_000_000_000)
        XCTAssertEqual(pattern.expectedEvents[12].measure, 2)
    }

    func testCanAnchorExpectedEventsToHostTimeline() throws {
        let pattern = try KickPatternGenerator().generate(
            configuration: KickPatternConfiguration(bpm: 60, subdivision: .eighths),
            startSessionTimeNanoseconds: 2_000_000_000,
            startHostTime: 10_000,
            hostTimeConverter: LinearHostTimeConverter(nanosecondsPerTick: 100)
        )

        XCTAssertEqual(pattern.expectedEvents[0].hostTime, 10_000)
        XCTAssertEqual(pattern.expectedEvents[1].hostTime, 5_010_000)
        XCTAssertEqual(pattern.expectedEvents[1].sessionTimeNanoseconds, 2_500_000_000)
    }

    func testEveryBuiltInExerciseGeneratesItsDocumentedHitCount() throws {
        for exercise in KickExercise.allCases {
            let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
                bpm: 120,
                exercise: exercise,
                measures: 3
            ))

            XCTAssertEqual(
                pattern.expectedEvents.count,
                exercise.hitsPerMeasure * 3,
                "Unexpected hit count for \(exercise.displayName)"
            )
            XCTAssertEqual(pattern.name, exercise.displayName)
        }
    }

    func testGallopUsesBeatThenAndAOnSixteenthGrid() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            exercise: .gallop
        ))

        XCTAssertEqual(pattern.expectedEvents.count, 12)
        XCTAssertEqual(pattern.expectedEvents.prefix(6).map(\.sessionTimeNanoseconds), [
            0, 250_000_000, 375_000_000,
            500_000_000, 750_000_000, 875_000_000
        ])
        XCTAssertEqual(pattern.expectedEvents.prefix(3).map(\.subdivision), [0, 2, 3])
    }

    func testOffbeatEighthsLeaveNumberedBeatsEmpty() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 60,
            exercise: .offbeatEighths
        ))

        XCTAssertEqual(pattern.expectedEvents.map(\.sessionTimeNanoseconds), [
            500_000_000, 1_500_000_000, 2_500_000_000, 3_500_000_000
        ])
        XCTAssertTrue(pattern.expectedEvents.allSatisfy { $0.subdivision == 1 })
    }

    func testAlternatingBlastCombinesCymbalAndKickThenSnare() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            exercise: .alternatingBlast
        ))

        let firstSlot = pattern.expectedEvents.filter { $0.sessionTimeNanoseconds == 0 }
        XCTAssertEqual(Set(firstSlot.map(\.voice)), [.crash1, .kick])
        XCTAssertEqual(Set(firstSlot.compactMap(\.simultaneousGroupID)).count, 1)
        XCTAssertNotNil(firstSlot.first?.simultaneousGroupID)

        let secondSlot = pattern.expectedEvents.filter { $0.sessionTimeNanoseconds == 125_000_000 }
        XCTAssertEqual(secondSlot.map(\.voice), [.snare])
        XCTAssertTrue(firstSlot.first(where: { $0.voice == .crash1 })?.allowedVoices.contains(.ride) == true)
    }

    func testUnisonBlastGroupsCymbalSnareAndKickOnEachEighthNote() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            exercise: .simultaneousBlast
        ))

        XCTAssertEqual(pattern.expectedEvents.count, 24)
        let firstSlot = pattern.expectedEvents.filter { $0.sessionTimeNanoseconds == 0 }
        XCTAssertEqual(Set(firstSlot.map(\.voice)), [.crash1, .snare, .kick])
        XCTAssertEqual(Set(firstSlot.compactMap(\.simultaneousGroupID)).count, 1)
    }

    func testOpenHatGrooveExpectsOnlyOpenHiHats() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 60,
            exercise: .discoGroove,
            measures: 2
        ))

        let hats = pattern.expectedEvents.filter {
            $0.voice == .openHiHat || $0.voice == .closedHiHat
        }
        XCTAssertEqual(hats.count, 16)
        XCTAssertTrue(hats.allSatisfy { $0.voice == .openHiHat })
        XCTAssertTrue(hats.allSatisfy { !$0.allowedVoices.contains(.closedHiHat) })
        XCTAssertFalse(pattern.expectedEvents.contains { $0.voice == .closedHiHat })
    }

    func testCustomMeasureRepeatsExactVoicesAndSimultaneousGroups() throws {
        let custom = CustomMeasureDefinition(
            name: "Verse groove",
            subdivision: .sixteenths,
            hits: [
                PracticeExerciseHit(slot: 0, voice: .kick),
                PracticeExerciseHit(slot: 0, voice: .snare),
                PracticeExerciseHit(slot: 6, voice: .ride)
            ]
        )

        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            customMeasure: custom,
            measures: 2
        ))

        XCTAssertEqual(pattern.name, "Verse groove")
        XCTAssertEqual(pattern.subdivision, .sixteenths)
        XCTAssertEqual(pattern.expectedEvents.count, 6)
        XCTAssertEqual(pattern.expectedEvents.filter { $0.measure == 1 }.map(\.voice), [.kick, .snare, .ride])
        XCTAssertEqual(pattern.expectedEvents.filter { $0.measure == 2 }.map(\.voice), [.kick, .snare, .ride])
        XCTAssertEqual(pattern.expectedEvents.first { $0.voice == .ride }?.sessionTimeNanoseconds, 750_000_000)
        XCTAssertEqual(pattern.expectedEvents.first { $0.measure == 2 }?.sessionTimeNanoseconds, 2_000_000_000)

        let firstUnison = pattern.expectedEvents.filter { $0.measure == 1 && $0.sessionTimeNanoseconds == 0 }
        let secondUnison = pattern.expectedEvents.filter { $0.measure == 2 && $0.sessionTimeNanoseconds == 2_000_000_000 }
        XCTAssertEqual(Set(firstUnison.compactMap(\.simultaneousGroupID)).count, 1)
        XCTAssertEqual(Set(secondUnison.compactMap(\.simultaneousGroupID)).count, 1)
        XCTAssertNotEqual(firstUnison.first?.simultaneousGroupID, secondUnison.first?.simultaneousGroupID)
    }

    func testCustomMeasureCanBeEditedRescaledAndGradedByExactVoice() throws {
        var custom = CustomMeasureDefinition(subdivision: .sixteenths)
        custom.toggle(slot: 0, voice: .kick)
        custom.toggle(slot: 4, voice: .snare)
        custom.toggle(slot: 4, voice: .snare)
        XCTAssertEqual(custom.hits, [PracticeExerciseHit(slot: 0, voice: .kick)])

        custom.toggle(slot: 4, voice: .snare)
        custom.rescale(to: .eighths)
        XCTAssertTrue(custom.contains(slot: 0, voice: .kick))
        XCTAssertTrue(custom.contains(slot: 2, voice: .snare))

        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            customMeasure: custom
        ))
        let actual = [
            performanceEvent(voice: .kick, milliseconds: 10),
            performanceEvent(voice: .highTom, milliseconds: 510)
        ]
        let matches = EventMatcher().match(expected: pattern.expectedEvents, actual: actual)

        XCTAssertEqual(matches.map(\.classification), [.correct, .wrongVoice])
        XCTAssertEqual(matches.compactMap(\.signedOffsetMilliseconds), [10, 10])
    }

    func testEmptyCustomMeasureCannotStartGeneration() {
        XCTAssertThrowsError(try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            customMeasure: CustomMeasureDefinition()
        ))) { error in
            XCTAssertEqual(error as? KickPatternGeneratorError, .emptyCustomMeasure)
        }
    }

    func testPlayheadCrossesNotesOnTheirScheduledTimes() throws {
        let measureWidth = 400.0
        let start: Int64 = 1_000_000_000
        let end: Int64 = 5_000_000_000

        let beatTwoPlayhead = try XCTUnwrap(PracticeScoreTimeline.playheadPosition(
            current: 2_000_000_000,
            start: start,
            end: end,
            slotsPerMeasure: 16,
            measureCount: 1,
            measureWidth: measureWidth
        ))
        XCTAssertEqual(
            beatTwoPlayhead,
            PracticeScoreTimeline.notePosition(
                measure: 0,
                slot: 4,
                slotsPerMeasure: 16,
                measureWidth: measureWidth
            ),
            accuracy: 0.000_001
        )

        let nextMeasurePlayhead = try XCTUnwrap(PracticeScoreTimeline.playheadPosition(
            current: 5_000_000_000,
            start: start,
            end: 9_000_000_000,
            slotsPerMeasure: 16,
            measureCount: 2,
            measureWidth: measureWidth
        ))
        XCTAssertEqual(
            nextMeasurePlayhead,
            PracticeScoreTimeline.notePosition(
                measure: 1,
                slot: 0,
                slotsPerMeasure: 16,
                measureWidth: measureWidth
            ),
            accuracy: 0.000_001
        )
    }

    func testRejectsUnsupportedConfigurations() {
        XCTAssertThrowsError(try KickPatternGenerator().generate(
            configuration: KickPatternConfiguration(bpm: 300, subdivision: .eighths)
        ))
        XCTAssertThrowsError(try KickPatternGenerator().generate(
            configuration: KickPatternConfiguration(bpm: 120, subdivision: .eighths, measures: 0)
        ))
    }

    private func performanceEvent(voice: DrumVoice, milliseconds: Int64) -> PerformanceEvent {
        PerformanceEvent(
            source: .midi,
            voice: voice,
            hostTime: UInt64(milliseconds * 1_000_000),
            sessionTimeNanoseconds: milliseconds * 1_000_000,
            rawMetadata: .simulated(label: "custom measure fixture")
        )
    }
}
