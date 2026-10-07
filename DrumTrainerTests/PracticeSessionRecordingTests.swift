import XCTest
import CoreAudio
@testable import DrumTrainer

final class PracticeSessionRecordingTests: XCTestCase {
    @MainActor
    func testSavedSequencePreservesSnapshotsReorderingRepeatsAndGradedHistory() throws {
        let suite = "SequenceTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsPracticeDataStore(defaults: defaults)
        let state = AppState(clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1), practiceDataStore: store,
            metronomeEngine: ControllableTestMetronome())
        state.practiceExerciseMode = .custom
        state.practiceCustomMeasure = CustomMeasureDefinition(name: "A", hits: [PracticeExerciseHit(slot: 0, voice: .snare)])
        state.saveCustomExercise()
        let a = try XCTUnwrap(state.selectedSavedCustomExerciseID)
        state.practiceCustomMeasure = CustomMeasureDefinition(name: "B", subdivision: .triplets, hits: [PracticeExerciseHit(slot: 1, voice: .openHiHat)])
        state.saveCustomExercise(asNew: true)
        let b = try XCTUnwrap(state.selectedSavedCustomExerciseID)
        state.setCustomSequenceMode(true)
        state.addCustomSequenceStep(savedID: a)
        state.addCustomSequenceStep(savedID: b)
        let firstID = try XCTUnwrap(state.practiceCustomMeasure.sequenceSteps?.first?.id)
        state.updateCustomSequenceStep(id: firstID, repeats: 4)
        XCTAssertEqual(state.practiceMeasures, 5)
        state.updateCustomSequenceStep(id: firstID, moveBy: 1)
        XCTAssertEqual(state.practiceCustomMeasure.sequenceSteps?.map(\.name), ["B", "A"])
        state.setCustomSequenceRepeats(2)
        XCTAssertEqual(state.practiceMeasures, 10)
        state.practiceCustomMeasure.name = "Transition practice"
        state.saveCustomExercise()
        let sequenceID = try XCTUnwrap(state.selectedSavedCustomExerciseID)
        XCTAssertNotEqual(sequenceID, b)
        state.deleteSavedCustomExercise(id: a)
        XCTAssertEqual(state.practicePreviewPattern?.expectedEvents.count, 10)

        let loaded = AppState(clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1), practiceDataStore: store,
            metronomeEngine: ControllableTestMetronome())
        loaded.loadSavedCustomExercise(id: sequenceID)
        XCTAssertEqual(loaded.practiceMeasures, 10)
        XCTAssertEqual(loaded.practiceCustomMeasure.sequenceSteps?.map(\.name), ["B", "A"])
        loaded.startPractice()
        for beat in 0..<9 {
            loaded.handlePracticeTick(MetronomeTick(hostTime: UInt64(1_000_000_000 + beat * 500_000_000), beat: beat % 4 + 1, isAccent: beat.isMultiple(of: 4)))
        }
        guard case .running = loaded.practicePhase else { return XCTFail("Sequence failed to start") }
        let pattern = try XCTUnwrap(loaded.practiceActivePattern)
        XCTAssertEqual(pattern.measures, 10)
        for note in pattern.expectedEvents {
            loaded.recordPracticeEvent(PerformanceEvent(source: .midi, voice: note.voice, hostTime: note.hostTime!,
                sessionTimeNanoseconds: note.sessionTimeNanoseconds,
                rawMetadata: .midi(channel: 9, note: 38, velocity: 100, endpointName: nil)))
        }
        loaded.finishPractice()
        XCTAssertEqual(loaded.practiceOutcome?.metrics.recall, 1)
        XCTAssertEqual(loaded.practiceHistory.first?.customExerciseID, sequenceID)
        let exported = try PracticeDataArchive.decodeAndValidate(loaded.exportPracticeData())
        XCTAssertEqual(exported.sessionRecords.first?.pattern.measureLabels, pattern.measureLabels)
        XCTAssertEqual(exported.sessionRecords.first?.pattern.measureSubdivisions, pattern.measureSubdivisions)
        loaded.dismissPracticeResults()
        loaded.updateCustomSequenceStep(id: firstID, remove: true)
        XCTAssertEqual(loaded.practiceMeasures, 2)
        loaded.setCustomSequenceMode(false)
        XCTAssertFalse(loaded.practiceCustomMeasure.isSequence)
        loaded.resetPracticeTransport()
    }

    func testLegacyCustomMeasuresMigrateAndInvalidSequencesCannotBeImported() throws {
        let measure = CustomMeasureDefinition(name: "Legacy", hits: [PracticeExerciseHit(slot: 0, voice: .snare)])
        let old = PracticeDataArchive(schemaVersion: 8, customExercises: [SavedCustomExercise(definition: measure)])
        let migrated = try PracticeDataArchive.decodeAndValidate(old.encodedJSON())
        XCTAssertEqual(migrated.schemaVersion, 9)
        XCTAssertFalse(try XCTUnwrap(migrated.customExercises.first).definition.isSequence)
        var invalid = measure
        invalid.sequenceSteps = [CustomMeasureStep(measure: measure, repeats: 0)]
        XCTAssertThrowsError(try PracticeDataArchive(customExercises: [SavedCustomExercise(definition: invalid)]).validatedAndMigrated())
    }

    func testExternalOnsetRequiresQuietAndSustainedSoundAndBackdatesConfirmation() {
        var detector = PlaybackOnsetDetector(thresholdDBFS: -45)
        for index in 0..<20 {
            XCTAssertNil(detector.consume(levelDBFS: -10, time: Double(index) * 0.01, duration: 0.01))
        }
        XCTAssertFalse(detector.isReady)
        for index in 20..<60 {
            XCTAssertNil(detector.consume(levelDBFS: -90, time: Double(index) * 0.01, duration: 0.01))
        }
        XCTAssertTrue(detector.isReady)
        XCTAssertNil(detector.consume(levelDBFS: -10, time: 0.60, duration: 0.005))
        XCTAssertNil(detector.consume(levelDBFS: -90, time: 0.605, duration: 0.005))
        XCTAssertNil(detector.consume(levelDBFS: -10, time: 0.61, duration: 0.01))
        XCTAssertEqual(detector.consume(levelDBFS: -10, time: 0.62, duration: 0.01), 0.61)
        XCTAssertNil(detector.consume(levelDBFS: -10, time: 0.63, duration: 0.01))
    }

    func testExternalOnsetRejectsInvalidSamplesAndReRequiresQuietAfterDiscontinuity() {
        var detector = PlaybackOnsetDetector(thresholdDBFS: .nan)
        XCTAssertEqual(detector.thresholdDBFS, -45)
        detector.observeSilentCaptureInterval()
        XCTAssertNil(detector.consume(levelDBFS: .nan, time: 0, duration: 0.02))
        XCTAssertNil(detector.consume(levelDBFS: -10, time: .infinity, duration: 0.02))
        XCTAssertNil(detector.consume(levelDBFS: -10, time: 0, duration: 0))
        XCTAssertNil(detector.consume(levelDBFS: -10, time: 0, duration: 0.01))
        XCTAssertNil(detector.consume(levelDBFS: -10, time: 2, duration: 0.02))
        XCTAssertFalse(detector.isReady)
        detector.observeSilentCaptureInterval()
        XCTAssertEqual(detector.consume(levelDBFS: -10, time: 3, duration: 0.02), 3)
    }

    @MainActor
    func testExternalPlaybackStartsWithoutClicksAndRetainsFirstHitButNotProgress() async throws {
        let listener = TestPlaybackListener()
        let transport = ControllableTestMetronome()
        let state = try makeExternalState(transport, listener: listener)
        state.startPractice()
        XCTAssertEqual(state.practicePhase, .waitingForPlayback)
        XCTAssertEqual(transport.startCount, 0)
        for _ in 0..<20 { await Task.yield() }
        state.recordPracticeEvent(PerformanceEvent(
            source: .midi, voice: .snare, hostTime: 100, sessionTimeNanoseconds: 0,
            velocity: 100.0 / 127.0, rawMetadata: .midi(channel: 9, note: 38, velocity: 100, endpointName: "test")
        ))
        try XCTUnwrap(listener.onsets.first)(100)
        guard case let .running(start, _) = state.practicePhase else { return XCTFail("No external start") }
        XCTAssertEqual(start, 0)
        XCTAssertEqual(state.practiceRecordedHitCount, 1)
        XCTAssertEqual(transport.startCount, 0)
        state.finishPractice()
        XCTAssertEqual(state.practicePhase, .results)
        XCTAssertEqual(state.practiceOutcome?.metrics.recall, 1)
        XCTAssertTrue(state.practiceHistory.isEmpty)
        XCTAssertTrue(state.practiceSessionRecords.isEmpty)
        XCTAssertNil(state.lastTempoProgressionMessage)
        XCTAssertGreaterThan(listener.stopCount, 0)
    }

    @MainActor
    func testExternalPlaybackRejectsOldCallbacksTimeoutsAndDuplicateOnsetsAcrossReplays() async throws {
        let listener = TestPlaybackListener()
        let transport = ControllableTestMetronome()
        let state = try makeExternalState(transport, listener: listener)
        for _ in 0..<20 {
            state.startPractice()
            let oldID = try XCTUnwrap(state.playbackArmID)
            for _ in 0..<10 { await Task.yield() }
            let oldOnset = try XCTUnwrap(listener.onsets.last)
            let oldError = try XCTUnwrap(listener.errors.last)
            state.cancelPractice()
            oldOnset(100)
            XCTAssertEqual(state.practicePhase, .idle)
            state.startPractice()
            let newID = try XCTUnwrap(state.playbackArmID)
            state.handlePlaybackWaitTimeout(id: oldID)
            oldError("stale failure")
            oldOnset(100)
            XCTAssertEqual(state.practicePhase, .waitingForPlayback)
            XCTAssertEqual(state.playbackArmID, newID)
            state.handleExternalPlaybackOnset(hostTime: 100, id: newID)
            let pattern = state.practiceActivePattern
            state.handleExternalPlaybackOnset(hostTime: 150, id: newID)
            XCTAssertEqual(state.practiceActivePattern, pattern)
            state.finishPractice()
            state.dismissPracticeResults()
        }
        XCTAssertEqual(transport.startCount, 0)
        state.resetPracticeTransport()
    }

    @MainActor
    func testExternalTimeoutPermissionFailureAndSyncLossLeaveRetryAvailable() async throws {
        let listener = TestPlaybackListener()
        let state = try makeExternalState(ControllableTestMetronome(), listener: listener)
        state.startPractice()
        state.handlePlaybackWaitTimeout(id: try XCTUnwrap(state.playbackArmID))
        guard case .error = state.practicePhase else { return XCTFail("Timeout must fail") }
        XCTAssertNil(state.playbackArmID)
        listener.shouldFail = true
        state.startPractice()
        for _ in 0..<20 { await Task.yield() }
        guard case .error = state.practicePhase else { return XCTFail("Permission failure must unlock") }
        listener.shouldFail = false
        state.startPractice()
        state.handleExternalPlaybackOnset(hostTime: 100, id: try XCTUnwrap(state.playbackArmID))
        state.markExternalPlaybackSyncLost()
        guard case .error = state.practicePhase else { return XCTFail("Sync loss must cancel") }
        XCTAssertNil(state.practiceOutcome)
        XCTAssertTrue(state.practiceHistory.isEmpty)
        state.startPractice()
        XCTAssertEqual(state.practicePhase, .waitingForPlayback)
        state.resetPracticeTransport()
        XCTAssertEqual(state.practicePhase, .idle)
    }

    @MainActor
    func testExternalStartOffsetAndNormalModeIsolation() throws {
        let listener = TestPlaybackListener()
        let transport = ControllableTestMetronome()
        let state = try makeExternalState(transport, listener: listener)
        state.playbackStartOffsetMilliseconds = 125
        state.startPractice()
        state.handleExternalPlaybackOnset(hostTime: 100, id: try XCTUnwrap(state.playbackArmID))
        XCTAssertEqual(state.practiceActivePattern?.startSessionTimeNanoseconds, 125_000_000)
        state.cancelPractice()
        state.playbackStartOffsetMilliseconds = -0.00005
        state.startPractice()
        state.handleExternalPlaybackOnset(hostTime: 100, id: try XCTUnwrap(state.playbackArmID))
        XCTAssertEqual(state.practiceActivePattern?.startSessionTimeNanoseconds, -50)
        state.resetPracticeTransport()
        state.practiceExerciseMode = .builtIn
        state.practiceExercise = .basicRockGroove
        state.startPractice()
        XCTAssertFalse(state.isExternalPlaybackRun)
        XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8))
        XCTAssertEqual(transport.startCount, 1)
        state.resetPracticeTransport()
    }

    @MainActor
    func testExternalPlaybackRequiresSourceSinglePassAndFreshTimestamp() throws {
        let state = try makeExternalState(ControllableTestMetronome(), listener: TestPlaybackListener())
        state.selectedPlaybackSourceID = nil
        state.startPractice()
        XCTAssertFalse(state.practicePhase.isActive)
        state.selectedPlaybackSourceID = 42
        state.importedSectionRepeats = 2
        state.startPractice()
        XCTAssertFalse(state.practicePhase.isActive)
        state.importedSectionRepeats = 1
        state.startPractice()
        state.handleExternalPlaybackOnset(hostTime: 99, id: try XCTUnwrap(state.playbackArmID))
        guard case .error = state.practicePhase else { return XCTFail("Old sample must not grade") }
        state.resetPracticeTransport()
    }

    @MainActor
    func testExternalPlaybackDiscardsTruncatedPreRollAndOutputChanges() throws {
        let state = try makeExternalState(ControllableTestMetronome(), listener: TestPlaybackListener())
        state.startPractice()
        for _ in 0..<513 {
            state.recordPracticeEvent(PerformanceEvent(
                source: .midi, voice: .snare, hostTime: 100, sessionTimeNanoseconds: 0,
                rawMetadata: .midi(channel: 9, note: 38, velocity: 100, endpointName: "test")
            ))
        }
        state.handleExternalPlaybackOnset(hostTime: 100, id: try XCTUnwrap(state.playbackArmID))
        guard case .error = state.practicePhase else { return XCTFail("Incomplete pre-roll must not grade") }
        state.startPractice()
        state.handleExternalPlaybackOnset(hostTime: 100, id: try XCTUnwrap(state.playbackArmID))
        state.selectAudioOutput(nil)
        guard case .error = state.practicePhase else { return XCTFail("Route change must invalidate alignment") }
        XCTAssertNil(state.practiceOutcome)
        state.resetPracticeTransport()
    }

    @MainActor
    private func makeExternalState(_ transport: ControllableTestMetronome, listener: TestPlaybackListener) throws -> AppState {
        let state = AppState(
            clock: FixedHostClock(hostTime: 100), converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
            practiceDataStore: DiscardingTransportTestStore(), metronomeEngine: transport,
            externalPlaybackListener: listener
        )
        try state.importStandardMIDI(Data([
            0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6, 0, 0, 0, 1, 1, 0xE0,
            0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 9,
            0, 0x99, 38, 100, 0x8F, 0, 0xFF, 0x2F, 0
        ]), filename: "External fixture.mid")
        state.waitForExternalPlayback = true
        state.selectedPlaybackSourceID = 42
        state.importedSectionRepeats = 1
        state.practiceBPM = 120
        return state
    }

    @MainActor
    func testAutoGoWaitsForChosenDelayAndRepeatsWithFreshCountInAndHistory() throws {
        let transport = ControllableTestMetronome()
        let state = makeTransportState(transport)
        state.setPracticeViewVisible(true)
        XCTAssertFalse(state.practiceAutoGoEnabled)
        state.practiceAutoGoEnabled = true
        state.practiceAutoGoDelaySeconds = 10
        state.practiceMeasures = 1
        state.startPractice()
        XCTAssertNil(state.practiceAutoGoSecondsRemaining)

        for attempt in 0..<3 {
            finishTransportPractice(state)
            XCTAssertEqual(state.practicePhase, .results)
            XCTAssertEqual(state.practiceHistory.count, attempt + 1)
            XCTAssertEqual(state.practiceAutoGoSecondsRemaining, 10)
            state.handlePracticeAutoGoTimer(at: 5_000_000_100)
            XCTAssertEqual(state.practiceAutoGoSecondsRemaining, 5)
            state.handlePracticeAutoGoTimer(at: 10_000_000_099)
            XCTAssertEqual(state.practicePhase, .results)
            XCTAssertEqual(state.practiceAutoGoSecondsRemaining, 1)
            state.handlePracticeAutoGoTimer(at: 10_000_000_100)
            XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8))
            XCTAssertNil(state.practiceOutcome)
            XCTAssertNil(state.practiceAutoGoSecondsRemaining)
            XCTAssertEqual(transport.startCount, attempt + 2)
        }
        XCTAssertEqual(Set(state.practiceHistory.map(\.id)).count, 3)
        state.cancelPractice()
    }

    @MainActor
    func testAutoGoCancellationAndManualReplayRejectPendingRestart() {
        for action in 0..<7 {
            let transport = ControllableTestMetronome()
            let state = makeTransportState(transport)
            state.setPracticeViewVisible(true)
            state.practiceAutoGoEnabled = true
            state.startPractice()
            finishTransportPractice(state)
            XCTAssertEqual(state.practiceAutoGoSecondsRemaining, 8)
            switch action {
            case 0: state.practiceAutoGoEnabled = false
            case 1: state.dismissPracticeResults()
            case 2: state.cancelPractice()
            case 3: state.resetPracticeTransport()
            case 4:
                state.setPracticeViewVisible(false)
                state.setPracticeViewVisible(true)
            case 5:
                state.dismissPracticeResults()
                state.startPractice()
            default: state.startPractice()
            }
            XCTAssertNil(state.practiceAutoGoSecondsRemaining)
            let phase = state.practicePhase
            let startCount = transport.startCount
            state.handlePracticeAutoGoTimer(at: 30_000_000_100)
            XCTAssertEqual(state.practicePhase, phase)
            XCTAssertEqual(transport.startCount, startCount)
            state.cancelPractice()
        }
    }

    @MainActor
    func testAutoGoDoesNotScheduleWhenDisabledOrPracticeIsHidden() {
        for enabled in [false, true] {
            let transport = ControllableTestMetronome()
            let state = makeTransportState(transport)
            state.practiceAutoGoEnabled = enabled
            state.setPracticeViewVisible(!enabled)
            state.startPractice()
            finishTransportPractice(state)
            XCTAssertNil(state.practiceAutoGoSecondsRemaining)
            state.handlePracticeAutoGoTimer(at: 30_000_000_100)
            XCTAssertEqual(state.practicePhase, .results)
            XCTAssertEqual(transport.startCount, 1)
            state.dismissPracticeResults()
        }
    }

    @MainActor
    func testTempoAutoAdvanceUsesPlayedBPMInsteadOfSavedSuggestion() throws {
        for (suggestion, bpm, step, expected) in [
            (120.0, 90.0, 5.0, 95.0),
            (130.0, 90.0, 5.0, 95.0),
            (95.0, 150.0, 7.0, 157.0),
            (130.0, 238.0, 7.0, 240.0)
        ] {
            let state = makeTransportState(ControllableTestMetronome())
            state.tempoProgressionSettings = TempoProgressionSettings(
                isEnabled: true, stepBPM: step, requiredCleanSessions: 3
            )
            // An initial attempt at the default tempo leaves a saved suggestion.
            state.startPractice()
            finishTransportPractice(state)
            XCTAssertEqual(state.currentTempoProgression?.suggestedBPM, 120)
            state.tempoProgressions[0].suggestedBPM = suggestion
            state.tempoProgressions[0].highestCleanBPM = 95
            state.dismissPracticeResults()
            state.practiceBPM = bpm
            XCTAssertEqual(state.nextTempoProgressionBPM, expected)

            for round in 1...3 {
                state.startPractice()
                finishTransportPractice(state, clean: true)
                XCTAssertTrue(try XCTUnwrap(state.practiceHistory.first).isClean)
                XCTAssertEqual(state.practiceHistory.first?.bpm, bpm)
                XCTAssertEqual(state.practiceBPM, round == 3 ? expected : bpm)
                XCTAssertEqual(state.currentTempoProgression?.consecutiveCleanSessions, round % 3)
                XCTAssertEqual(state.currentTempoProgression?.suggestedBPM, round == 3 ? expected : bpm)
                XCTAssertEqual(state.currentTempoProgression?.highestCleanBPM, max(95, bpm))
                state.dismissPracticeResults()
            }
            XCTAssertEqual(
                state.lastTempoProgressionMessage,
                "Advanced \(state.practiceExercise.displayName) to \(Int(expected)) BPM."
            )
            state.resetPracticeTransport()
        }
    }

    @MainActor
    func testAutoGoRepeatsFromLoweredTempoAndUsesChangedRaiseAmount() throws {
        let state = makeTransportState(ControllableTestMetronome())
        state.tempoProgressionSettings = TempoProgressionSettings(
            isEnabled: true, stepBPM: 5, requiredCleanSessions: 3
        )
        state.startPractice()
        finishTransportPractice(state)
        state.tempoProgressions[0].suggestedBPM = 130
        state.tempoProgressions[0].highestCleanBPM = 95
        state.dismissPracticeResults()
        state.practiceBPM = 90
        state.setPracticeViewVisible(true)
        state.practiceAutoGoEnabled = true
        state.practiceAutoGoDelaySeconds = 5
        state.startPractice()

        for round in 1...6 {
            finishTransportPractice(state, clean: true)
            let expectedBPM = round < 3 ? 90.0 : (round < 6 ? 95.0 : 102.0)
            XCTAssertEqual(state.practiceBPM, expectedBPM)
            state.handlePracticeAutoGoTimer(at: 5_000_000_100)
            XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8))
            XCTAssertEqual(state.practiceBPM, expectedBPM)
            if round == 3 {
                state.tempoProgressionSettings.stepBPM = 7
                state.saveTempoProgressionSettings()
                XCTAssertEqual(state.nextTempoProgressionBPM, 102)
            }
        }
        XCTAssertEqual(state.practiceHistory.prefix(6).map(\.bpm), [95, 95, 95, 90, 90, 90])
        state.resetPracticeTransport()
    }

    @MainActor
    func testAutoGoUsesAdvancedTempoAndStopsWhenCeilingIsFound() throws {
        for ceiling in [false, true] {
            let transport = ControllableTestMetronome()
            let state = makeTransportState(transport)
            state.setPracticeViewVisible(true)
            state.practiceAutoGoEnabled = true
            state.practiceAutoGoDelaySeconds = 5
            if ceiling {
                state.ceilingModeSettings = CeilingModeSettings(isEnabled: true, stepBPM: 5)
            } else {
                state.tempoProgressionSettings = TempoProgressionSettings(
                    isEnabled: true, stepBPM: 5, requiredCleanSessions: 1
                )
            }
            state.startPractice()
            finishTransportPractice(state, clean: true)
            XCTAssertTrue(try XCTUnwrap(state.practiceHistory.first).isClean)
            XCTAssertEqual(state.practiceAutoGoSecondsRemaining, 5)
            state.handlePracticeAutoGoTimer(at: 5_000_000_100)
            XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8))
            XCTAssertEqual(state.practiceBPM, 125)
            finishTransportPractice(state)
            if ceiling {
                guard case .found = state.activeCeilingRun?.phase else { return XCTFail("Ceiling should be found") }
                XCTAssertNil(state.practiceAutoGoSecondsRemaining)
                state.handlePracticeAutoGoTimer(at: 30_000_000_100)
                XCTAssertEqual(state.practicePhase, .results)
                XCTAssertEqual(transport.startCount, 2)
            }
            state.cancelPractice()
        }
    }

    @MainActor
    func testAutoGoRearmsExternalPlaybackWithoutStartingClicks() async throws {
        let transport = ControllableTestMetronome()
        let listener = TestPlaybackListener()
        let state = try makeExternalState(transport, listener: listener)
        state.setPracticeViewVisible(true)
        state.practiceAutoGoEnabled = true
        state.startPractice()
        let oldID = try XCTUnwrap(state.playbackArmID)
        state.handleExternalPlaybackOnset(hostTime: 100, id: oldID)
        state.finishPractice()
        XCTAssertEqual(state.practiceAutoGoSecondsRemaining, 8)
        state.handlePracticeAutoGoTimer(at: 8_000_000_100)
        XCTAssertEqual(state.practicePhase, .waitingForPlayback)
        XCTAssertNotEqual(state.playbackArmID, oldID)
        XCTAssertEqual(transport.startCount, 0)
        XCTAssertTrue(state.practiceHistory.isEmpty)
        state.cancelPractice()
    }

    @MainActor
    private func finishTransportPractice(_ state: AppState, clean: Bool = false) {
        for beat in 0..<9 {
            state.handlePracticeTick(MetronomeTick(
                hostTime: UInt64(1_000_000_000 + beat * 500_000_000),
                beat: beat % 4 + 1, isAccent: beat.isMultiple(of: 4)
            ))
        }
        guard case .running = state.practicePhase else { return XCTFail("Practice did not start") }
        if clean {
            for note in state.practiceExpectedEvents {
                state.recordPracticeEvent(PerformanceEvent(
                    source: .midi, voice: note.voice, hostTime: note.hostTime!,
                    sessionTimeNanoseconds: note.sessionTimeNanoseconds,
                    rawMetadata: .midi(channel: 9, note: 38, velocity: 100, endpointName: nil)
                ))
            }
        }
        state.finishPractice()
    }

    @MainActor
    func testSixtyPracticeReplaysCompleteCountInAndReturnToStartableState() throws {
        let transport = ControllableTestMetronome()
        let state = makeTransportState(transport)
        state.practiceMeasures = 1
        for attempt in 0..<60 {
            state.practiceExercise = attempt.isMultiple(of: 2) ? .basicRockGroove : .discoGroove
            state.startPractice()
            XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8))
            for beat in 0..<9 {
                state.handlePracticeTick(MetronomeTick(
                    hostTime: UInt64(1_000_000_000 + beat * 500_000_000),
                    beat: beat % 4 + 1, isAccent: beat.isMultiple(of: 4)
                ))
            }
            guard case .running = state.practicePhase else { return XCTFail("Replay \(attempt) did not start") }
            state.finishPractice()
            XCTAssertEqual(state.practicePhase, .results)
            state.dismissPracticeResults()
            XCTAssertEqual(state.practicePhase, .idle)
            XCTAssertFalse(state.isRefreshingAudioEngine)
        }
        XCTAssertEqual(transport.startCount, 60)
        XCTAssertEqual(state.practiceHistory.count, 60)
        state.resetPracticeTransport()
    }

    @MainActor
    func testCancelledRefreshAlwaysUnlocksWithoutRestartingPractice() async {
        let transport = ControllableTestMetronome()
        let state = makeTransportState(transport)
        state.startPractice()
        state.refreshAudioEngineAndRetryPractice()
        state.cancelPractice()
        transport.completeRefresh(at: 0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(state.isRefreshingAudioEngine)
        XCTAssertEqual(state.practicePhase, .idle)
        XCTAssertEqual(transport.startCount, 1)
    }

    @MainActor
    func testTimeoutUnlocksEvenAfterFlowChangesAndRejectsLateCompletion() async throws {
        let transport = ControllableTestMetronome()
        let state = makeTransportState(transport)
        state.startPractice()
        state.refreshAudioEngineAndRetryPractice()
        let refreshID = try XCTUnwrap(state.audioEngineRefreshID)
        state.cancelPractice()
        state.handleAudioRefreshTimeout(requestID: refreshID)
        XCTAssertFalse(state.isRefreshingAudioEngine)
        state.startPractice()
        transport.completeRefresh(at: 0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.startCount, 2)
        XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8))
        state.resetPracticeTransport()
    }

    @MainActor
    func testOldRefreshCannotReleaseNewRefreshOrRepeatedRetryStrandCountdown() async throws {
        let transport = ControllableTestMetronome()
        let state = makeTransportState(transport)
        state.refreshAudioEngine()
        let oldID = try XCTUnwrap(state.audioEngineRefreshID)
        state.resetPracticeTransport()
        state.refreshAudioEngine()
        let newID = try XCTUnwrap(state.audioEngineRefreshID)
        state.refreshAudioEngineAndRetryPractice()
        XCTAssertEqual(state.practicePhase, .idle)
        transport.completeRefresh(at: 0)
        for _ in 0..<20 { await Task.yield() }
        state.handleAudioRefreshTimeout(requestID: oldID)
        XCTAssertTrue(state.isRefreshingAudioEngine)
        XCTAssertEqual(state.audioEngineRefreshID, newID)
        transport.completeRefresh(at: 1)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(state.isRefreshingAudioEngine)
        XCTAssertEqual(state.practicePhase, .idle)
    }

    @MainActor
    func testCountInStallRetriesOnceThenOffersRecoverableError() async {
        let transport = ControllableTestMetronome()
        let state = makeTransportState(transport)
        state.startPractice()
        state.handlePracticeTick(MetronomeTick(hostTime: 1, beat: 1, isAccent: true))
        XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8), "Old ticks must not advance a new run")
        state.recoverFromMetronomeStall()
        transport.completeRefresh(at: 0)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(transport.startCount, 2)
        state.recoverFromMetronomeStall()
        guard case .error = state.practicePhase else { return XCTFail("Second stall must end in an error") }
        XCTAssertFalse(state.isRefreshingAudioEngine)
        state.resetPracticeTransport()
        state.startPractice()
        XCTAssertEqual(state.practicePhase, .countIn(beatsRemaining: 8))
        state.resetPracticeTransport()
    }

    @MainActor
    private func makeTransportState(_ transport: ControllableTestMetronome) -> AppState {
        let state = AppState(
            clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
            practiceDataStore: DiscardingTransportTestStore(),
            metronomeEngine: transport
        )
        state.practiceExercise = .basicRockGroove
        state.practiceBPM = 120
        return state
    }

    func testKickFreeScoringExcludesExpectedAndDetectedKicksFromEveryMetric() throws {
        let pattern = PracticePattern(
            name: "Open hat fixture",
            bpm: 60,
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
                    subdivision: 0,
                    sessionTimeNanoseconds: 1_000_000_000,
                    voice: .openHiHat
                ),
                ExpectedEvent(
                    measure: 1,
                    beat: 2,
                    subdivision: 0,
                    sessionTimeNanoseconds: 2_000_000_000,
                    voice: .snare
                )
            ]
        )
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 4_000_000_000,
            scoringConfiguration: PracticeScoringConfiguration(gradeKicks: false)
        )
        recording.record(event(at: 1_005_000_000, voice: .openHiHat, source: .midi))
        recording.record(event(at: 1_400_000_000, voice: .kick, source: .microphone))
        recording.record(event(at: 2_010_000_000, voice: .snare, source: .midi))

        XCTAssertEqual(recording.actualEvents.count, 3)
        XCTAssertEqual(recording.scoredActualEventCount, 2)

        let outcome = recording.finish()
        XCTAssertFalse(outcome.effectiveScoringConfiguration.gradeKicks)
        XCTAssertEqual(outcome.pattern.expectedEvents.count, 3)
        XCTAssertEqual(outcome.actualEvents.count, 3)
        XCTAssertEqual(outcome.matchResults.count, 2)
        XCTAssertEqual(outcome.metrics.totalExpected, 2)
        XCTAssertEqual(outcome.metrics.totalPlayed, 2)
        XCTAssertEqual(outcome.metrics.correctCount, 2)
        XCTAssertEqual(outcome.metrics.missedCount, 0)
        XCTAssertEqual(outcome.metrics.extraCount, 0)
        XCTAssertEqual(outcome.metrics.wrongVoiceCount, 0)
        XCTAssertEqual(outcome.metrics.recall, 1)
        XCTAssertEqual(outcome.metrics.precision, 1)
        XCTAssertFalse(outcome.metrics.perVoice.contains { $0.voice == .kick })
        XCTAssertFalse(outcome.timingTimeline.entries.contains {
            $0.expectedVoice == .kick || $0.playedVoice == .kick
        })

        let summary = PracticeSessionSummary(outcome: outcome, exerciseKind: .builtIn)
        var record = PracticeSessionRecord(summary: summary, outcome: outcome)
        record.rescore()
        XCTAssertEqual(record.metrics, outcome.metrics)
        XCTAssertFalse(record.outcome.effectiveScoringConfiguration.gradeKicks)

        let archive = PracticeDataArchive(sessions: [record.summary], sessionRecords: [record])
        let decoded = try PracticeDataArchive.decodeAndValidate(archive.encodedJSON())
        let decodedRecord = try XCTUnwrap(decoded.sessionRecords.first)
        XCTAssertFalse(decodedRecord.outcome.effectiveScoringConfiguration.gradeKicks)
        XCTAssertEqual(decodedRecord.metrics.totalExpected, 2)
    }

    func testLegacySessionRecordWithoutScoringConfigurationStillGradesKicks() throws {
        let pattern = makePattern()
        var recording = PracticeSessionRecording(
            pattern: pattern,
            exerciseEndSessionTimeNanoseconds: 1_250_000_000
        )
        recording.record(event(at: 1_005_000_000))
        recording.record(event(at: 1_130_000_000))
        let outcome = recording.finish()
        let record = PracticeSessionRecord(
            summary: PracticeSessionSummary(outcome: outcome, exerciseKind: .builtIn),
            outcome: outcome
        )
        let encoded = try JSONEncoder().encode(record)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "scoringConfiguration")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        var decoded = try JSONDecoder().decode(PracticeSessionRecord.self, from: legacyData)
        XCTAssertNil(decoded.scoringConfiguration)
        XCTAssertTrue(decoded.outcome.effectiveScoringConfiguration.gradeKicks)
        decoded.rescore()
        XCTAssertEqual(decoded.metrics.totalExpected, 2)
        XCTAssertEqual(decoded.metrics.correctCount, 2)
    }

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
    func testResetPracticeTransportUnlocksLatchedRefreshState() throws {
        let suiteName = "PracticeTransportResetTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(
            clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
            practiceDataStore: UserDefaultsPracticeDataStore(defaults: defaults)
        )
        state.practicePhase = .countIn(beatsRemaining: 8)
        state.isRefreshingAudioEngine = true

        state.resetPracticeTransport()

        XCTAssertEqual(state.practicePhase, .idle)
        XCTAssertFalse(state.isRefreshingAudioEngine)
        XCTAssertEqual(state.practiceRecordedHitCount, 0)
        XCTAssertNotNil(state.audioEngineRecoveryMessage)
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

    @MainActor
    func testTimingAlignmentRetryRestartsTransportWithoutAppRelaunch() {
        let transport = ControllableTestMetronome()
        let state = AppState(
            clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
            practiceDataStore: DiscardingTransportTestStore(),
            metronomeEngine: transport
        )
        state.midiDevices = [MIDIInputDevice(id: 42, endpoint: 0, name: "Test e-kit")]
        state.selectedMIDIInputID = 42
        state.timingAlignmentPhase = .error("Previous run failed")

        state.retryTimingAlignment()

        XCTAssertEqual(transport.stopCount, 1)
        XCTAssertEqual(transport.startCount, 1)
        XCTAssertEqual(state.timingAlignmentPhase, .starting)

        state.handleTimingAlignmentMetronomeStatus(.running("Test output"))
        XCTAssertEqual(state.timingAlignmentPhase, .countIn(beatsRemaining: AppState.countInBeats))

        state.timingAlignmentPhase = .error("Try again")
        state.refreshAudioEngineAndRetryTimingAlignment()
        XCTAssertEqual(transport.stopCount, 2)
        XCTAssertEqual(transport.startCount, 2)
        XCTAssertEqual(state.timingAlignmentPhase, .starting)
    }

    func testGhostSessionArchiveRescoresAndUngradedKicksDoNotAffectDynamics() throws {
        var definition = CustomMeasureDefinition()
        definition.toggle(slot: 0, voice: .snare)
        definition.toggleGhost(slot: 4, voice: .snare)
        definition.toggleGhost(slot: 8, voice: .kick)
        let pattern = try KickPatternGenerator().generate(configuration: KickPatternConfiguration(
            bpm: 120, customMeasure: definition
        ))
        var recording = PracticeSessionRecording(
            pattern: pattern, exerciseEndSessionTimeNanoseconds: pattern.exactDurationNanoseconds,
            scoringConfiguration: PracticeScoringConfiguration(gradeKicks: false)
        )
        for expected in pattern.expectedEvents where expected.voice == .snare {
            recording.record(PerformanceEvent(
                source: .midi, voice: expected.voice,
                hostTime: UInt64(expected.sessionTimeNanoseconds),
                sessionTimeNanoseconds: expected.sessionTimeNanoseconds,
                velocity: (expected.isGhost ? 40.0 : 90.0) / 127,
                rawMetadata: .simulated(label: "ghost archive fixture")
            ))
        }
        let outcome = recording.finish()
        let summary = PracticeSessionSummary(outcome: outcome, exerciseKind: .custom)
        XCTAssertTrue(summary.isClean)
        XCTAssertEqual(summary.ghostMetrics?.expectedCount, 1)
        let record = PracticeSessionRecord(summary: summary, outcome: outcome)
        let archive = PracticeDataArchive(sessions: [summary], sessionRecords: [record])
        let decoded = try PracticeDataArchive.decodeAndValidate(archive.encodedJSON())
        var restored = try XCTUnwrap(decoded.sessionRecords.first)
        restored.rescore()
        XCTAssertEqual(restored.summary.ghostMetrics, summary.ghostMetrics)
        XCTAssertEqual(restored.pattern.expectedEvents, pattern.expectedEvents)
        XCTAssertTrue(restored.summary.isClean)

        let badActual = outcome.actualEvents.map { actual in
            PerformanceEvent(
                source: .midi, voice: actual.voice, hostTime: actual.hostTime,
                sessionTimeNanoseconds: actual.sessionTimeNanoseconds,
                velocity: 90.0 / 127, rawMetadata: .simulated(label: "flat dynamics")
            )
        }
        var badRecording = PracticeSessionRecording(
            pattern: pattern, exerciseEndSessionTimeNanoseconds: pattern.exactDurationNanoseconds,
            scoringConfiguration: PracticeScoringConfiguration(gradeKicks: false)
        )
        badActual.forEach { badRecording.record($0) }
        let badOutcome = badRecording.finish()
        XCTAssertEqual(badOutcome.metrics.recall, 1)
        XCTAssertFalse(PracticeSessionSummary(outcome: badOutcome, exerciseKind: .custom).isClean)
    }

    func testLegacyArchiveWithoutGhostFieldsKeepsHistoryAndNoteMeaning() throws {
        let pattern = makePattern()
        let recording = PracticeSessionRecording(
            pattern: pattern, exerciseEndSessionTimeNanoseconds: pattern.exactDurationNanoseconds
        )
        let outcome = recording.finish()
        let summary = PracticeSessionSummary(outcome: outcome, exerciseKind: .builtIn)
        let archive = PracticeDataArchive(
            schemaVersion: 7, sessions: [summary],
            sessionRecords: [PracticeSessionRecord(summary: summary, outcome: outcome)]
        )
        let decoded = try PracticeDataArchive.decodeAndValidate(JSONEncoder().encode(archive))
        XCTAssertNil(decoded.sessions[0].ghostMetrics)
        XCTAssertTrue(decoded.sessionRecords[0].pattern.expectedEvents.allSatisfy { !$0.isGhost })
        let legacyHit = Data(#"{"slot":0,"voice":"snare","allowedVoices":[],"accent":true}"#.utf8)
        let hit = try JSONDecoder().decode(PracticeExerciseHit.self, from: legacyHit)
        XCTAssertTrue(hit.isAccent)
        XCTAssertFalse(hit.isGhost)
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

private struct DiscardingTransportTestStore: PracticeDataPersisting {
    func load() throws -> PracticeDataArchive { PracticeDataArchive() }
    func save(_ archive: PracticeDataArchive) throws {}
}

@MainActor
private final class TestPlaybackListener: ExternalPlaybackListening {
    var onsets: [@MainActor (UInt64) -> Void] = []
    var errors: [@MainActor (String) -> Void] = []
    var stopCount = 0
    var shouldFail = false
    func sources() async throws -> [PlaybackAudioSource] { [PlaybackAudioSource(id: 42, name: "Test browser")] }
    func start(sourceID: Int32, thresholdDBFS: Double,
               onLevel: @escaping @MainActor (Double, Bool) -> Void,
               onOnset: @escaping @MainActor (UInt64) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws {
        if shouldFail { throw NSError(domain: "Permission denied", code: 1) }
        onsets.append(onOnset)
        errors.append(onError)
    }
    func stop() { stopCount += 1 }
}

private final class ControllableTestMetronome: MetronomeControlling {
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var completions: [@Sendable () -> Void] = []
    func startMonitoring() {}
    func select(deviceID: AudioDeviceID?) {}
    func start(bpm: Double) { startCount += 1 }
    func stop() { stopCount += 1 }
    func rebuildAudioGraph(completion: @escaping @Sendable () -> Void) { completions.append(completion) }
    func completeRefresh(at index: Int) { completions[index]() }
    func updateBPM(_ bpm: Double) {}
    func updateSound(_ sound: MetronomeSound) {}
    func updateGainDecibels(_ gain: Double) {}
    func updateLimiter(enabled: Bool, ceilingDBFS: Double) {}
    func updateKickMonitoring(enabled: Bool, sound: KickMonitorSound, gainDecibels: Double,
                              velocitySensitive: Bool, retriggerMilliseconds: Double, startAudioIfNeeded: Bool) {}
    func triggerKick(velocity: Double, eventHostTime: UInt64, respectsRetriggerLockout: Bool) {}
    func followTempoMap(startPresentationHostTime: UInt64, referenceBeats: [PracticeReferenceBeat]) {}
}
