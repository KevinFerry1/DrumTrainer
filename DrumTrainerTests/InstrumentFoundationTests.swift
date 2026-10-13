import CoreAudio
import XCTest
@testable import DrumTrainer

final class InstrumentFoundationTests: XCTestCase {
    func testPitchIdentityKeepsOctavesAndRejectsInvalidMIDIValues() throws {
        let middleC = try XCTUnwrap(MIDIPitch(60))
        let highC = try XCTUnwrap(MIDIPitch(72))
        XCTAssertEqual(middleC.displayName, "C4")
        XCTAssertEqual(middleC.pitchClass, highC.pitchClass)
        XCTAssertNotEqual(MusicalTarget.pitched(middleC), .pitched(highC))
        XCTAssertNotEqual(MusicalTarget.pitched(middleC), .drum(.snare))
        XCTAssertNil(MIDIPitch(-1))
        XCTAssertNil(MIDIPitch(128))
        XCTAssertThrowsError(try JSONDecoder().decode(MIDIPitch.self, from: Data("128".utf8)))
        XCTAssertEqual(try JSONDecoder().decode(MIDIPitch.self, from: JSONEncoder().encode(middleC)), middleC)
    }

    func testPitchedNotesPreserveDurationChordAndAuthoredFingering() throws {
        let note = PitchedExpectedNote(pitch: try XCTUnwrap(MIDIPitch(64)), onsetNanoseconds: 10,
                                      durationNanoseconds: 500, chordID: UUID(), part: .rightHand,
                                      fingering: GuitarFingering(string: 1, fret: 0))
        XCTAssertTrue(note.isValid)
        XCTAssertEqual(try JSONDecoder().decode(PitchedExpectedNote.self, from: JSONEncoder().encode(note)), note)
        XCTAssertFalse(PitchedExpectedNote(pitch: note.pitch, onsetNanoseconds: 0, durationNanoseconds: -1).isValid)
        XCTAssertFalse(PitchedExpectedNote(pitch: note.pitch, onsetNanoseconds: .max, durationNanoseconds: 1).isValid)
        XCTAssertFalse(PitchedExpectedNote(pitch: note.pitch, onsetNanoseconds: 0,
                                          fingering: GuitarFingering(string: 0, fret: 0)).isValid)
    }

    func testMigrationLabelsLegacyEvidenceAsDrumsWithoutChangingScores() throws {
        let pattern = makePattern()
        var recording = PracticeSessionRecording(pattern: pattern, exerciseEndSessionTimeNanoseconds: 2_000)
        recording.record(makeEvent(hostTime: 1_000))
        let outcome = recording.finish()
        let summary = PracticeSessionSummary(outcome: outcome, exerciseKind: .custom)
        let song = ImportedSong(name: "Legacy song", sourceFilename: "legacy.mid", format: 1,
                                ticksPerQuarterNote: 480, tempoChanges: [], timeSignatureChanges: [],
                                tracks: [ImportedMIDITrack(index: 0, name: "Drums", notes: [])],
                                selectedTrackIndex: 0, noteMappings: [])
        let archive = PracticeDataArchive(schemaVersion: 9,
            customExercises: [SavedCustomExercise(definition: CustomMeasureDefinition())], importedSongs: [song],
            sessions: [summary], sessionRecords: [PracticeSessionRecord(summary: summary, outcome: outcome)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as? [String: Any])
        json.removeValue(forKey: "instrumentProfiles")
        for key in ["customExercises", "importedSongs", "sessions", "sessionRecords"] {
            var values = try XCTUnwrap(json[key] as? [[String: Any]])
            for index in values.indices {
                values[index].removeValue(forKey: "instrument")
                if var nested = values[index]["summary"] as? [String: Any] {
                    nested.removeValue(forKey: "instrument")
                    values[index]["summary"] = nested
                }
            }
            json[key] = values
        }
        let migrated = try PracticeDataArchive.decodeAndValidate(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(migrated.schemaVersion, PracticeDataArchive.currentSchemaVersion)
        XCTAssertEqual(Set(migrated.instrumentProfiles.map(\.instrument)), Set(InstrumentKind.allCases))
        XCTAssertEqual(migrated.customExercises.first?.instrument, .drums)
        XCTAssertEqual(migrated.importedSongs.first?.instrument, .drums)
        XCTAssertEqual(migrated.sessions.first?.instrument, .drums)
        XCTAssertEqual(migrated.sessions.first?.id, summary.id)
        XCTAssertEqual(migrated.sessions.first?.recall, summary.recall)
        XCTAssertEqual(migrated.sessions.first?.scoringVersion, summary.scoringVersion)
        XCTAssertEqual(migrated.sessionRecords.first?.actualEvents, outcome.actualEvents)
        XCTAssertEqual(migrated.sessionRecords.first?.matchResults, outcome.matchResults)
        XCTAssertEqual(try PracticeDataArchive.decodeAndValidate(migrated.encodedJSON()), migrated)
        // A missing instrument field is also compatible when only the nested
        // record summary lacks it, as can happen when archives are combined.
        var summaries = try XCTUnwrap(json["sessions"] as? [[String: Any]])
        summaries[0]["instrument"] = "drums"
        json["sessions"] = summaries
        let partial = try PracticeDataArchive.decodeAndValidate(JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(partial, migrated)
    }

    func testEverySupportedLegacySchemaGetsMissingProfiles() throws {
        for version in 1...9 {
            let json = Data("{\"schemaVersion\":\(version)}".utf8)
            let migrated = try PracticeDataArchive.decodeAndValidate(json)
            XCTAssertEqual(migrated.schemaVersion, PracticeDataArchive.currentSchemaVersion)
            XCTAssertEqual(migrated.instrumentProfiles.count, 3)
        }
    }

    func testInvalidProfilesAndMislabeledDrumDataAreRejected() throws {
        let profile = InstrumentProfile(instrument: .drums)
        XCTAssertThrowsError(try PracticeDataArchive(instrumentProfiles: [profile, profile]).validatedAndMigrated())
        var invalid = profile
        invalid.practiceBPM = .nan
        XCTAssertThrowsError(try PracticeDataArchive(instrumentProfiles: [invalid]).validatedAndMigrated())
        invalid = profile
        invalid.measures = 0
        XCTAssertThrowsError(try PracticeDataArchive(instrumentProfiles: [invalid]).validatedAndMigrated())
        var saved = SavedCustomExercise(definition: CustomMeasureDefinition())
        saved.instrument = .electricPiano
        XCTAssertThrowsError(try PracticeDataArchive(customExercises: [saved]).validatedAndMigrated())
        let partial = try PracticeDataArchive(instrumentProfiles: [profile]).validatedAndMigrated()
        XCTAssertEqual(partial.instrumentProfiles.count, 3)
    }

    func testProgressNamespacesPreserveDrumKeys() {
        XCTAssertEqual(InstrumentKind.drums.progressionKey(for: "groove"), "groove")
        XCTAssertNotEqual(InstrumentKind.electricPiano.progressionKey(for: "groove"),
                          InstrumentKind.electricGuitar.progressionKey(for: "groove"))
    }

    @MainActor
    func testUnsavedDrumDraftSurvivesRelaunchWithoutEnteringNamedLibrary() {
        let defaults = makeDefaults()
        let store = UserDefaultsPracticeDataStore(defaults: defaults)
        let state = makeState(store: store, defaults: defaults)
        state.practiceExerciseMode = .custom
        state.practiceCustomMeasure = CustomMeasureDefinition(name: "Still editing", hits: [PracticeExerciseHit(slot: 1, voice: .snare)])
        let draft = state.practiceCustomMeasure
        state.selectInstrument(.electricPiano)
        let reloaded = makeState(store: store, defaults: defaults)
        reloaded.selectInstrument(.drums)
        XCTAssertEqual(reloaded.practiceExerciseMode, .custom)
        XCTAssertEqual(reloaded.practiceCustomMeasure, draft)
        XCTAssertTrue(reloaded.savedCustomExercises.isEmpty)
    }

    @MainActor
    func testLegacyBackupDoesNotOverwriteOtherInstrumentSetup() throws {
        let state = makeState(defaults: makeDefaults())
        state.selectInstrument(.electricPiano)
        state.practiceBPM = 85
        state.updateActiveInstrumentProfile { $0.midiInputID = 42 }
        state.selectInstrument(.drums)
        try state.importPracticeData(Data("{\"schemaVersion\":9}".utf8))
        state.selectInstrument(.electricPiano)
        XCTAssertEqual(state.practiceBPM, 85)
        XCTAssertEqual(state.activeInstrumentProfile.midiInputID, 42)
    }

    @MainActor
    func testProfilesAndLastInstrumentSurviveRelaunchAndExport() throws {
        let defaults = makeDefaults()
        let store = UserDefaultsPracticeDataStore(defaults: defaults)
        let state = makeState(store: store, defaults: defaults)
        state.practiceBPM = 150
        state.practiceMeasures = 6
        state.selectInstrument(.electricPiano)
        XCTAssertEqual(state.practiceBPM, 120)
        state.practiceBPM = 85
        state.updateActiveInstrumentProfile { $0.midiInputID = 42; $0.audioOutputUID = "piano-output" }
        state.selectInstrument(.electricGuitar)
        state.practiceBPM = 100
        state.updateActiveInstrumentProfile { $0.audioInputUID = "guitar-input" }
        let reloaded = makeState(store: store, defaults: defaults)
        XCTAssertEqual(reloaded.selectedInstrument, .electricGuitar)
        XCTAssertEqual(reloaded.practiceBPM, 100)
        XCTAssertEqual(reloaded.activeInstrumentProfile.audioInputUID, "guitar-input")
        reloaded.selectInstrument(.electricPiano)
        XCTAssertEqual(reloaded.practiceBPM, 85)
        XCTAssertEqual(reloaded.activeInstrumentProfile.midiInputID, 42)
        reloaded.selectInstrument(.drums)
        XCTAssertEqual(reloaded.practiceBPM, 150)
        XCTAssertEqual(reloaded.practiceMeasures, 6)
        let exported = try PracticeDataArchive.decodeAndValidate(reloaded.exportPracticeData())
        XCTAssertEqual(exported.instrumentProfiles.first { $0.instrument == .electricPiano }?.practiceBPM, 85)
        XCTAssertEqual(exported.instrumentProfiles.first { $0.instrument == .electricGuitar }?.audioInputUID, "guitar-input")
    }

    @MainActor
    func testSwitchDuringCountInCancelsWithoutSavingAndPreservesDraft() throws {
        let state = makeState(defaults: makeDefaults())
        state.practiceCustomMeasure = CustomMeasureDefinition(name: "Unsaved", hits: [PracticeExerciseHit(slot: 0, voice: .snare)])
        let draft = state.practiceCustomMeasure
        state.startPractice()
        XCTAssertTrue(state.practicePhase.isActive)
        state.selectInstrument(.electricPiano)
        state.handlePracticeTick(MetronomeTick(hostTime: 1_000, beat: 1, isAccent: true))
        state.finishPractice()
        XCTAssertEqual(state.practicePhase, .idle)
        XCTAssertNil(state.practiceActivePattern)
        XCTAssertNil(state.practiceOutcome)
        XCTAssertTrue(state.practiceHistory.isEmpty)
        state.selectInstrument(.drums)
        XCTAssertEqual(state.practiceCustomMeasure, draft)
        state.startPractice()
        XCTAssertTrue(state.practicePhase.isActive)
        state.cancelPractice()
    }

    @MainActor
    func testSwitchDuringRunningPracticeDiscardsPartialEvidence() throws {
        let state = makeState(defaults: makeDefaults())
        state.startPractice()
        tickCountIn(state)
        XCTAssertNotNil(state.practiceActivePattern)
        state.selectInstrument(.electricGuitar)
        state.recordPracticeEvent(makeEvent(hostTime: 10_000))
        state.finishPractice()
        XCTAssertEqual(state.practiceRecordedHitCount, 0)
        XCTAssertTrue(state.practiceHistory.isEmpty)
        XCTAssertTrue(state.practiceSessionRecords.isEmpty)
    }

    @MainActor
    func testSwitchCancelsCalibrationAndDisablesUnimplementedPracticePaths() {
        let state = makeState(defaults: makeDefaults())
        state.microphoneCalibrationPhase = .samplingNoise(secondsRemaining: 2)
        state.timingAlignmentPhase = .countIn(beatsRemaining: 8)
        state.selectInstrument(.electricPiano)
        XCTAssertEqual(state.microphoneCalibrationPhase, .idle)
        XCTAssertEqual(state.timingAlignmentPhase, .idle)
        state.startPractice()
        state.startMicrophoneCalibration()
        state.startTimingAlignment()
        state.toggleSimulation()
        state.refreshAudioEngineAndRetryPractice()
        XCTAssertEqual(state.practicePhase, .idle)
        XCTAssertFalse(state.isSimulationRunning)
        XCTAssertFalse(state.isRefreshingAudioEngine)
    }

    @MainActor
    func testSwitchCancelsAutoGoButPreservesCompletedDrumHistory() throws {
        let state = makeState(defaults: makeDefaults())
        state.setPracticeViewVisible(true)
        state.startPractice()
        tickCountIn(state)
        state.finishPractice()
        XCTAssertEqual(state.practicePhase, .results)
        XCTAssertNotNil(state.practiceAutoGoSecondsRemaining)
        let history = state.practiceHistory
        state.selectInstrument(.electricPiano)
        state.handlePracticeAutoGoTimer(at: .max)
        XCTAssertNil(state.practiceAutoGoSecondsRemaining)
        XCTAssertEqual(state.practiceHistory, history)
        XCTAssertEqual(history.first?.effectiveInstrument, .drums)
        XCTAssertEqual(state.practicePhase, .idle)
    }

    @MainActor
    func testOldAudioRefreshCannotRestartAfterInstrumentSwitch() async {
        let transport = InstrumentTestMetronome()
        let state = makeState(defaults: makeDefaults(), transport: transport)
        state.startPractice()
        state.refreshAudioEngine(retryActiveFlow: true)
        state.selectInstrument(.electricPiano)
        let starts = transport.startCount
        transport.completeRefresh()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(state.practicePhase, .idle)
        XCTAssertFalse(state.isRefreshingAudioEngine)
        XCTAssertEqual(transport.startCount, starts)
    }

    @MainActor
    func testSessionControllerRejectsStaleEvidenceAndClearsAcrossModes() {
        let controller = PracticeSessionController()
        controller.recording = PracticeSessionRecording(pattern: makePattern(), exerciseEndSessionTimeNanoseconds: 2_000)
        controller.sessionID = UUID()
        controller.pendingBounds = (1_000, 2_000)
        let generation = controller.generation
        controller.activate(.electricPiano, at: 500)
        XCTAssertNotEqual(controller.generation, generation)
        XCTAssertNil(controller.recording)
        XCTAssertNil(controller.sessionID)
        XCTAssertNil(controller.pendingBounds)
        XCTAssertFalse(controller.accepts(makeEvent(hostTime: 1_000)))
        controller.activate(.drums, at: 1_001)
        XCTAssertFalse(controller.accepts(makeEvent(hostTime: 1_000)))
        XCTAssertTrue(controller.accepts(makeEvent(hostTime: 1_001)))
    }

    private func makeDefaults() -> UserDefaults {
        let name = "InstrumentFoundationTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    private func makeState(store: (any PracticeDataPersisting)? = nil, defaults: UserDefaults,
                           transport: InstrumentTestMetronome = InstrumentTestMetronome()) -> AppState {
        let state = AppState(clock: FixedHostClock(hostTime: 100), converter: LinearHostTimeConverter(nanosecondsPerTick: 1),
                             practiceDataStore: store ?? UserDefaultsPracticeDataStore(defaults: defaults),
                             metronomeEngine: transport, userPreferences: defaults)
        state.practiceExercise = .basicRockGroove
        return state
    }

    @MainActor
    private func tickCountIn(_ state: AppState) {
        for beat in 0..<9 {
            state.handlePracticeTick(MetronomeTick(hostTime: UInt64(1_000_000_000 + beat * 500_000_000),
                                                  beat: beat % 4 + 1, isAccent: beat.isMultiple(of: 4)))
        }
    }

    private func makePattern() -> PracticePattern {
        PracticePattern(name: "Drum fixture", bpm: 120, beatsPerMeasure: 4, measures: 1,
                        expectedEvents: [ExpectedEvent(measure: 1, beat: 1, subdivision: 0,
                                                       sessionTimeNanoseconds: 1_000, voice: .snare)])
    }

    private func makeEvent(hostTime: UInt64) -> PerformanceEvent {
        PerformanceEvent(source: .midi, voice: .snare, hostTime: hostTime, sessionTimeNanoseconds: 1_000,
                         rawMetadata: .midi(channel: 10, note: 38, velocity: 100, endpointName: nil))
    }
}

private final class InstrumentTestMetronome: MetronomeControlling {
    var startCount = 0
    private var completion: (@Sendable () -> Void)?
    func startMonitoring() {}
    func select(deviceID: AudioDeviceID?) {}
    func start(bpm: Double) { startCount += 1 }
    func stop() {}
    func rebuildAudioGraph(completion: @escaping @Sendable () -> Void) { self.completion = completion }
    func completeRefresh() { completion?() }
    func updateBPM(_ bpm: Double) {}
    func updateSound(_ sound: MetronomeSound) {}
    func updateGainDecibels(_ gain: Double) {}
    func updateLimiter(enabled: Bool, ceilingDBFS: Double) {}
    func updateKickMonitoring(enabled: Bool, sound: KickMonitorSound, gainDecibels: Double,
                              velocitySensitive: Bool, retriggerMilliseconds: Double, startAudioIfNeeded: Bool) {}
    func triggerKick(velocity: Double, eventHostTime: UInt64, respectsRetriggerLockout: Bool) {}
    func followTempoMap(startPresentationHostTime: UInt64, referenceBeats: [PracticeReferenceBeat]) {}
}
