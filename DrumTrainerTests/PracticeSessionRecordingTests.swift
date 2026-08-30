import XCTest
@testable import DrumTrainer

final class PracticeSessionRecordingTests: XCTestCase {
    func testRecordsOnlyExerciseWindowAndProducesOutcome() {
        let pattern = makePattern()
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 1_250_000_000
        )

        recording.record(event(at: 899_000_000))
        recording.record(referenceEvent(at: 1_000_000_000))
        recording.record(event(at: 1_005_000_000))
        recording.record(event(at: 1_135_000_000))
        recording.record(event(at: 1_250_000_000))
        recording.record(event(at: 1_351_000_000))

        let outcome = recording.finish()

        XCTAssertEqual(outcome.actualEvents.count, 3)
        XCTAssertEqual(outcome.metrics.correctCount, 2)
        XCTAssertEqual(outcome.metrics.extraCount, 1)
        XCTAssertEqual(outcome.metrics.missedCount, 0)
        XCTAssertEqual(outcome.metrics.recall, 1)
        XCTAssertEqual(outcome.metrics.precision, 2.0 / 3.0, accuracy: 0.0001)
    }

    func testSessionRecordingIsBoundedAndReportsDroppedEvents() {
        let pattern = makePattern()
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 1_250_000_000,
            capacity: 1
        )

        recording.record(event(at: 1_005_000_000))
        recording.record(event(at: 1_135_000_000))

        let outcome = recording.finish()
        XCTAssertEqual(outcome.actualEvents.count, 1)
        XCTAssertEqual(outcome.droppedEventCount, 1)
    }

    func testHitDuringLeadingRestIsScoredAsExtra() throws {
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 60,
            exercise: .offbeatEighths
        ))
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 4_000_000_000
        )

        recording.record(event(at: 0))
        for expected in pattern.expectedEvents {
            recording.record(event(at: expected.sessionTimeNanoseconds))
        }

        let outcome = recording.finish()
        XCTAssertEqual(outcome.metrics.correctCount, 4)
        XCTAssertEqual(outcome.metrics.extraCount, 1)
        XCTAssertEqual(outcome.metrics.missedCount, 0)
    }

    func testTimingTimelinePreservesChronologyMusicalPositionAndInputEvidence() throws {
        let pattern = PracticePattern(
            name: "Timeline fixture",
            bpm: 120,
            beatsPerMeasure: 4,
            measures: 1,
            startSessionTimeNanoseconds: 1_000_000_000,
            expectedEvents: [
                ExpectedEvent(
                    measure: 1,
                    beat: 1,
                    subdivision: 0,
                    sessionTimeNanoseconds: 1_000_000_000,
                    voice: .kick
                ),
                ExpectedEvent(
                    measure: 1,
                    beat: 2,
                    subdivision: 0,
                    sessionTimeNanoseconds: 1_500_000_000,
                    voice: .snare
                ),
                ExpectedEvent(
                    measure: 1,
                    beat: 2,
                    subdivision: 1,
                    sessionTimeNanoseconds: 1_750_000_000,
                    voice: .kick
                )
            ]
        )
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 3_000_000_000
        )
        recording.record(event(at: 1_010_000_000))
        recording.record(event(at: 1_520_000_000, voice: .highTom, source: .midi))
        recording.record(event(at: 2_000_000_000, voice: .ride, source: .midi))

        let timeline = recording.finish().timingTimeline

        XCTAssertEqual(timeline.startSessionTimeNanoseconds, 1_000_000_000)
        XCTAssertEqual(timeline.endSessionTimeNanoseconds, 3_000_000_000)
        XCTAssertEqual(timeline.entries.map(\.classification), [.correct, .wrongVoice, .missed, .extra])

        let correct = try XCTUnwrap(timeline.entries.first { $0.classification == .correct })
        XCTAssertEqual(correct.measure, 1)
        XCTAssertEqual(correct.beat, 1)
        XCTAssertEqual(correct.subdivision, 0)
        XCTAssertEqual(correct.expectedVoice, .kick)
        XCTAssertEqual(correct.playedVoice, .kick)
        XCTAssertEqual(correct.signedOffsetMilliseconds, 10)
        XCTAssertEqual(correct.source, .microphone)
        XCTAssertFalse(correct.isProblem)

        let wrongVoice = try XCTUnwrap(timeline.entries.first { $0.classification == .wrongVoice })
        XCTAssertEqual(wrongVoice.expectedVoice, .snare)
        XCTAssertEqual(wrongVoice.playedVoice, .highTom)
        XCTAssertEqual(wrongVoice.source, .midi)
        XCTAssertTrue(wrongVoice.isProblem)

        let missed = try XCTUnwrap(timeline.entries.first { $0.classification == .missed })
        XCTAssertNil(missed.actualEventID)
        XCTAssertNil(missed.playedVoice)
        XCTAssertNil(missed.source)

        let extra = try XCTUnwrap(timeline.entries.first { $0.classification == .extra })
        XCTAssertNil(extra.expectedEventID)
        XCTAssertNil(extra.expectedVoice)
        XCTAssertEqual(extra.playedVoice, .ride)
        XCTAssertEqual(extra.actualTimeNanoseconds, 2_000_000_000)
    }

    func testPracticeArchiveRoundTripsNamedExercisesAndSessionProgress() throws {
        let suiteName = "PracticeDataStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPracticeDataStore(defaults: defaults)

        var definition = CustomMeasureDefinition(name: "Chorus groove", subdivision: .eighths)
        definition.toggle(slot: 0, voice: .kick)
        definition.toggle(slot: 2, voice: .snare)
        let saved = SavedCustomExercise(
            id: UUID(),
            definition: definition,
            createdAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 2_000)
        )

        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120,
            customMeasure: definition
        ))
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 2_000_000_000
        )
        for expected in pattern.expectedEvents {
            recording.record(event(at: expected.sessionTimeNanoseconds, voice: expected.voice, source: .midi))
        }
        let summary = PracticeSessionSummary(
            id: UUID(),
            completedAt: Date(timeIntervalSince1970: 3_000),
            outcome: recording.finish(),
            exerciseKind: .custom,
            customExerciseID: saved.id
        )
        let archive = PracticeDataArchive(customExercises: [saved], sessions: [summary])

        try store.save(archive)
        let loaded = try store.load()

        XCTAssertEqual(loaded, archive)
        XCTAssertEqual(loaded.customExercises.first?.definition.displayName, "Chorus groove")
        XCTAssertEqual(loaded.sessions.first?.customExerciseID, saved.id)
        XCTAssertEqual(loaded.sessions.first?.recall, 1)
        XCTAssertEqual(loaded.sessions.first?.durationSeconds, 2)
        XCTAssertTrue(try XCTUnwrap(loaded.sessions.first).isClean)
    }

    func testSchemaV3ArchivePreservesRescorableEvidenceNotesTagsDevicesAndCeilingState() throws {
        let pattern = makePattern()
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 1_250_000_000
        )
        recording.record(event(at: 1_005_000_000, source: .midi))
        recording.record(event(at: 1_135_000_000, source: .midi))
        let outcome = recording.finish()
        let summary = PracticeSessionSummary(outcome: outcome, exerciseKind: .builtIn)
        var record = PracticeSessionRecord(
            summary: summary,
            outcome: outcome,
            deviceContext: PracticeSessionDeviceContext(
                midiDeviceID: 42,
                midiDeviceName: "Test kit",
                audioOutputUID: "output-1",
                audioOutputName: "Headphones"
            )
        )
        record.updateMetadata(notes: "  Relax the ankle  ", tags: ["chorus", "speed", "chorus"])
        let progression = ExerciseTempoProgression(
            id: "built-in:Fixture",
            exerciseName: "Fixture",
            suggestedBPM: 125,
            consecutiveCleanSessions: 1,
            highestCleanBPM: 120,
            updatedAt: Date(timeIntervalSince1970: 4_000)
        )
        let ceilingRun = CeilingRun(
            id: UUID(),
            exerciseID: "built-in:Fixture",
            exerciseName: "Fixture",
            exerciseKind: .builtIn,
            customExerciseID: nil,
            startedAt: Date(timeIntervalSince1970: 3_500),
            updatedAt: Date(timeIntervalSince1970: 4_000),
            startingBPM: 120,
            highestCleanBPM: 120,
            attemptedBPMs: [120],
            sessionIDs: [summary.id],
            phase: .readyForNext(bpm: 125)
        )
        let ceilingRecord = ExerciseCeilingRecord(
            id: "built-in:Fixture",
            exerciseName: "Fixture",
            highestVerifiedBPM: 120,
            achievedAt: Date(timeIntervalSince1970: 4_000),
            ceilingRunID: ceilingRun.id,
            startingBPM: 100,
            failedBPM: 125,
            roundsCompleted: 5
        )
        let archive = PracticeDataArchive(
            sessions: [summary],
            sessionRecords: [record],
            tempoProgressionSettings: TempoProgressionSettings(
                isEnabled: false,
                stepBPM: 5,
                requiredCleanSessions: 3
            ),
            tempoProgressions: [progression],
            ceilingModeSettings: CeilingModeSettings(isEnabled: true, stepBPM: 5),
            activeCeilingRun: ceilingRun,
            ceilingRecords: [ceilingRecord]
        )

        let decoded = try PracticeDataArchive.decodeAndValidate(archive.encodedJSON(prettyPrinted: true))

        XCTAssertEqual(decoded, archive)
        let decodedRecord = try XCTUnwrap(decoded.sessionRecords.first)
        XCTAssertEqual(decodedRecord.actualEvents, outcome.actualEvents)
        XCTAssertEqual(decodedRecord.pattern, pattern)
        XCTAssertEqual(decodedRecord.notes, "Relax the ankle")
        XCTAssertEqual(decodedRecord.tags, ["chorus", "speed"])
        XCTAssertEqual(decodedRecord.deviceContext.midiDeviceName, "Test kit")
        XCTAssertEqual(decodedRecord.outcome, outcome)
        XCTAssertFalse(decoded.tempoProgressionSettings.isEnabled)
        XCTAssertEqual(decoded.tempoProgressions.first?.suggestedBPM, 125)
        XCTAssertTrue(decoded.ceilingModeSettings.isEnabled)
        XCTAssertEqual(decoded.activeCeilingRun, ceilingRun)
        XCTAssertEqual(decoded.ceilingRecords, [ceilingRecord])
    }

    func testCeilingRunAdvancesAfterCleanRoundAndStopsAtLastVerifiedTempo() throws {
        let clean120 = try makeSummary(bpm: 120, clean: true)
        let failed125 = try makeSummary(bpm: 125, clean: false)
        var run = CeilingRun(
            id: UUID(),
            exerciseID: "built-in:Fixture",
            exerciseName: "Fixture",
            exerciseKind: .builtIn,
            customExerciseID: nil,
            startedAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1),
            startingBPM: 120,
            highestCleanBPM: nil,
            attemptedBPMs: [],
            sessionIDs: [],
            phase: .testing(bpm: 120)
        )

        XCTAssertEqual(
            run.record(clean120, stepBPM: 5),
            .advance(passedBPM: 120, nextBPM: 125)
        )
        XCTAssertEqual(run.phase, .readyForNext(bpm: 125))
        XCTAssertEqual(run.highestCleanBPM, 120)

        XCTAssertEqual(
            run.record(failed125, stepBPM: 5),
            .found(highestCleanBPM: 120, failedBPM: 125)
        )
        XCTAssertEqual(
            run.phase,
            .found(highestCleanBPM: 120, failedBPM: 125)
        )
        XCTAssertEqual(run.attemptedBPMs, [120, 125])
        XCTAssertEqual(run.sessionIDs, [clean120.id, failed125.id])
    }

    func testCeilingRunReportsStartingTempoTooHighAndCapsAt240() throws {
        var failedRun = CeilingRun(
            id: UUID(),
            exerciseID: "custom-name:Fast part",
            exerciseName: "Fast part",
            exerciseKind: .custom,
            customExerciseID: nil,
            startedAt: Date(),
            updatedAt: Date(),
            startingBPM: 160,
            highestCleanBPM: nil,
            attemptedBPMs: [],
            sessionIDs: [],
            phase: .testing(bpm: 160)
        )
        XCTAssertEqual(
            failedRun.record(try makeSummary(bpm: 160, clean: false), stepBPM: 5),
            .belowStartingTempo(failedBPM: 160)
        )

        var maximumRun = CeilingRun(
            id: UUID(),
            exerciseID: "built-in:Fixture",
            exerciseName: "Fixture",
            exerciseKind: .builtIn,
            customExerciseID: nil,
            startedAt: Date(),
            updatedAt: Date(),
            startingBPM: 240,
            highestCleanBPM: nil,
            attemptedBPMs: [],
            sessionIDs: [],
            phase: .testing(bpm: 240)
        )
        XCTAssertEqual(
            maximumRun.record(try makeSummary(bpm: 240, clean: true), stepBPM: 20),
            .maximumVerified(bpm: 240)
        )
        XCTAssertEqual(
            maximumRun.phase,
            .found(highestCleanBPM: 240, failedBPM: nil)
        )
    }

    func testSchemaV1SummaryArchiveMigratesWithoutLosingHistory() throws {
        let pattern = makePattern()
        let outcome = PracticeSessionOutcome(
            pattern: pattern,
            actualEvents: [],
            matchResults: EventMatcher().match(expected: pattern.expectedEvents, actual: []),
            metrics: ScoringMetricsCalculator().calculate(
                from: EventMatcher().match(expected: pattern.expectedEvents, actual: []),
                expectedEvents: pattern.expectedEvents,
                actualEvents: []
            ),
            droppedEventCount: 0
        )
        let summary = PracticeSessionSummary(outcome: outcome, exerciseKind: .builtIn)
        let encoded = try JSONEncoder().encode(PracticeDataArchive(
            schemaVersion: 1,
            sessions: [summary]
        ))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "sessionRecords")
        object.removeValue(forKey: "tempoProgressionSettings")
        object.removeValue(forKey: "tempoProgressions")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let migrated = try PracticeDataArchive.decodeAndValidate(legacyData)

        XCTAssertEqual(migrated.schemaVersion, PracticeDataArchive.currentSchemaVersion)
        XCTAssertEqual(migrated.sessions, [summary])
        XCTAssertTrue(migrated.sessionRecords.isEmpty)
        XCTAssertEqual(migrated.tempoProgressionSettings, TempoProgressionSettings())
    }

    func testArchiveValidationRejectsDuplicateIdentifiers() throws {
        var definition = CustomMeasureDefinition(name: "Duplicate")
        definition.toggle(slot: 0, voice: .kick)
        let saved = SavedCustomExercise(definition: definition)
        let archive = PracticeDataArchive(customExercises: [saved, saved])

        XCTAssertThrowsError(try archive.encodedJSON()) { error in
            guard case PracticeDataPersistenceError.invalidArchive = error else {
                return XCTFail("Expected invalid archive, got \(error)")
            }
        }
    }

    @MainActor
    func testAppStateCreatesUpdatesCopiesLoadsAndDeletesSavedCustomExercises() throws {
        let suiteName = "SavedCustomExerciseStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsPracticeDataStore(defaults: defaults)
        let state = AppState(
            clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
            practiceDataStore: store
        )
        state.practiceExerciseMode = .custom
        state.practiceCustomMeasure.name = "Saved verse"
        state.toggleCustomMeasureHit(slot: 0, voice: .kick)

        state.saveCustomExercise()
        let originalID = try XCTUnwrap(state.selectedSavedCustomExerciseID)
        XCTAssertEqual(state.savedCustomExercises.count, 1)

        state.toggleCustomMeasureHit(slot: 4, voice: .snare)
        state.saveCustomExercise()
        XCTAssertEqual(state.savedCustomExercises.count, 1)
        XCTAssertTrue(try XCTUnwrap(state.savedCustomExercises.first).definition.contains(slot: 4, voice: .snare))

        state.practiceCustomMeasure.name = "Saved verse copy"
        state.saveCustomExercise(asNew: true)
        XCTAssertEqual(state.savedCustomExercises.count, 2)

        let reloaded = AppState(
            clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
            practiceDataStore: store
        )
        XCTAssertEqual(reloaded.savedCustomExercises.count, 2)
        reloaded.loadSavedCustomExercise(id: originalID)
        XCTAssertEqual(reloaded.practiceCustomMeasure.displayName, "Saved verse")
        XCTAssertTrue(reloaded.practiceCustomMeasure.contains(slot: 4, voice: .snare))

        reloaded.deleteSavedCustomExercise(id: originalID)
        XCTAssertEqual(reloaded.savedCustomExercises.count, 1)
        XCTAssertNil(reloaded.selectedSavedCustomExerciseID)
        XCTAssertEqual(try store.load().customExercises.count, 1)
    }

    @MainActor
    func testTimingAlignmentWaitsForMetronomeRestartAndSurfacesStartupFailure() throws {
        let suiteName = "TimingAlignmentLifecycleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
            timingAlignmentStore: UserDefaultsTimingAlignmentStore(defaults: defaults),
            practiceDataStore: UserDefaultsPracticeDataStore(defaults: defaults)
        )

        state.timingAlignmentPhase = .starting
        state.handleTimingAlignmentMetronomeStatus(.running("Focusrite Solo"))
        XCTAssertEqual(state.timingAlignmentPhase, .countIn(beatsRemaining: AppState.countInBeats))

        state.timingAlignmentPhase = .starting
        state.handleTimingAlignmentMetronomeStatus(.error("Core Audio restart failed"))
        XCTAssertEqual(state.timingAlignmentPhase, .error("Core Audio restart failed"))
    }

    private func makePattern() -> PracticePattern {
        PracticePattern(
            name: "Fixture",
            bpm: 120,
            beatsPerMeasure: 4,
            measures: 1,
            expectedEvents: [
                ExpectedEvent(
                    measure: 1,
                    beat: 1,
                    subdivision: 0,
                    sessionTimeNanoseconds: 1_000_000_000,
                    voice: .kick
                ),
                ExpectedEvent(
                    measure: 1,
                    beat: 1,
                    subdivision: 1,
                    sessionTimeNanoseconds: 1_125_000_000,
                    voice: .kick
                )
            ]
        )
    }

    private func makeSummary(bpm: Double, clean: Bool) throws -> PracticeSessionSummary {
        let pattern = PracticePattern(
            name: "Fixture",
            bpm: bpm,
            beatsPerMeasure: 4,
            measures: 1,
            expectedEvents: [
                ExpectedEvent(
                    measure: 1,
                    beat: 1,
                    subdivision: 0,
                    sessionTimeNanoseconds: 1_000_000_000,
                    voice: .kick
                )
            ]
        )
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 2_000_000_000
        )
        if clean {
            recording.record(event(at: 1_000_000_000))
        }
        return PracticeSessionSummary(
            outcome: recording.finish(),
            exerciseKind: .builtIn
        )
    }

    private func event(
        at time: Int64,
        voice: DrumVoice = .kick,
        source: EventSource = .microphone
    ) -> PerformanceEvent {
        PerformanceEvent(
            source: source,
            voice: voice,
            hostTime: UInt64(time),
            sessionTimeNanoseconds: time,
            rawMetadata: .simulated(label: "practice fixture")
        )
    }

    private func referenceEvent(at time: Int64) -> PerformanceEvent {
        PerformanceEvent(
            source: .metronome,
            voice: .metronome,
            hostTime: UInt64(time),
            sessionTimeNanoseconds: time,
            rawMetadata: .metronome(beat: 1, subdivision: 0)
        )
    }
}
