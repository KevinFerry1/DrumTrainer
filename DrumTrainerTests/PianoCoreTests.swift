import CoreMIDI
import CoreAudio
import SwiftUI
import XCTest
@testable import DrumTrainer

final class PianoCoreTests: XCTestCase {
    func testParsesPressReleaseVelocityZeroPedalAndBend() throws {
        XCTAssertEqual(try message(0x2090_3C64).payload, .noteOn(note: 60, velocity: 100))
        XCTAssertEqual(try message(0x2090_3C00).payload, .noteOff(note: 60, velocity: 0))
        XCTAssertEqual(try message(0x2080_3C32).payload, .noteOff(note: 60, velocity: 50))
        XCTAssertEqual(try message(0x20BF_4040).channel, 16)
        XCTAssertEqual(try message(0x20BF_4040).payload, .controlChange(controller: 64, value: 64))
        XCTAssertEqual(try message(0x20E0_0040).payload, .pitchBend(value: 8192))
        XCTAssertEqual(try message(0x20E0_7F7F).payload, .pitchBend(value: 16383))
        XCTAssertEqual(try message(0x2590_3C64).group, 5)
        XCTAssertNil(MIDI1UMPParser.channelEvent(from: 0x4090_3C64, hostTime: 1))
        XCTAssertNil(MIDI1UMPParser.channelEvent(from: 0x2090_BC64, hostTime: 1))
    }

    func testPacketWalkingDoesNotTreatSysExPayloadAsNotes() {
        let parsed = MIDI1UMPParser.channelEvents(words: [0x3000_0000, 0x2090_3C64, 0x2090_4064], hostTime: 123)
        XCTAssertEqual(parsed.events.count, 1)
        XCTAssertEqual(parsed.events.first?.payload, .noteOn(note: 64, velocity: 100))
        XCTAssertEqual(parsed.events.first?.hostTime, 123)
        XCTAssertEqual(parsed.dropped, 0)
        XCTAssertEqual(MIDI1UMPParser.channelEvents(words: [0x5000_0000], hostTime: 1).dropped, 1)
        XCTAssertEqual(MIDI1UMPParser.channelEvents(words: [0x6000_0000, 0x2090_3C64], hostTime: 1).events.count, 0)
    }

    func testNativeCoreMIDIReceivesPacketLargerThan64Words() async throws {
        var client = MIDIClientRef(), source = MIDIEndpointRef()
        let clientResult = MIDIClientCreateWithBlock("Piano core capture test" as CFString, &client) { _ in }
        guard clientResult == noErr else { throw XCTSkip("CoreMIDI is unavailable on this host.") }
        defer { MIDIClientDispose(client) }
        let sourceResult = MIDISourceCreateWithProtocol(client, "Piano test source \(UUID())" as CFString, ._1_0, &source)
        guard sourceResult == noErr else { throw XCTSkip("Virtual MIDI sources are unavailable on this host.") }
        defer { MIDIEndpointDispose(source) }
        var id = MIDIUniqueID()
        XCTAssertEqual(MIDIObjectGetIntegerProperty(source, kMIDIPropertyUniqueID, &id), noErr)
        let received = expectation(description: "Receive complete dynamic packet")
        let capture = PianoBatchCapture()
        let service = MIDIInputService(onDevicesChanged: { _ in }, onNoteOn: { _, _ in }, onStatusChanged: { _ in },
            onMessages: { batch in capture.set(batch); received.fulfill() })
        service.start()
        service.select(deviceID: id)
        let bytes = UnsafeMutableRawPointer.allocate(byteCount: 8_192, alignment: MemoryLayout<MIDIEventList>.alignment)
        defer { bytes.deallocate() }
        let list = bytes.bindMemory(to: MIDIEventList.self, capacity: 1)
        let packet = MIDIEventListInit(list, ._1_0)
        let words = (0..<96).map { UInt32(0x2090_0064) | UInt32($0) << 8 }
        let added = words.withUnsafeBufferPointer { MIDIEventListAdd(list, 8_192, packet, 1, words.count, $0.baseAddress!) }
        XCTAssertNotNil(added)
        XCTAssertEqual(list.pointee.packet.wordCount, 96)
        XCTAssertEqual(MIDIReceivedEventList(source, list), noErr)
        await fulfillment(of: [received], timeout: 3)
        let batch = try XCTUnwrap(capture.get())
        XCTAssertEqual(batch.events.count, 96)
        XCTAssertEqual(batch.droppedCount, 0)
        XCTAssertEqual(batch.events.last?.payload, .noteOn(note: 95, velocity: 100))
        service.select(deviceID: nil)
        XCTAssertNotEqual(batch.connectionGeneration, service.connectionGeneration)
    }

    func testKeyReleaseAndSustainedEndAreDifferent() throws {
        var tracker = PianoNoteTracker()
        tracker.process(try input(0x2090_3C64, at: 0))
        tracker.process(try input(0x20B0_407F, at: 10))
        tracker.process(try input(0x2080_3C00, at: 20))
        XCTAssertEqual(tracker.orderedNotes.first?.keyReleaseNanoseconds, 20)
        XCTAssertNil(tracker.orderedNotes.first?.soundingEndNanoseconds)
        XCTAssertTrue(tracker.heldPitches.isEmpty)
        XCTAssertEqual(tracker.soundingPitches, [MIDIPitch(60)!])
        tracker.process(try input(0x20B0_403F, at: 30))
        XCTAssertEqual(tracker.orderedNotes.first?.soundingEndNanoseconds, 30)
        XCTAssertTrue(tracker.soundingPitches.isEmpty)
    }

    func testReattackingReleasedPitchUnderPedalCreatesDistinctNotes() throws {
        var tracker = PianoNoteTracker()
        for (word, time): (UInt32, Int64) in [(0x20B0_407F,0),(0x2090_3C64,10),(0x2080_3C00,20),
                                             (0x2090_3C70,30),(0x2090_3C00,40),(0x20B0_4000,50)] {
            tracker.process(try input(word, at: time))
        }
        XCTAssertEqual(tracker.orderedNotes.count, 2)
        XCTAssertEqual(tracker.orderedNotes.map(\.keyReleaseNanoseconds), [20,40])
        XCTAssertEqual(tracker.orderedNotes.map(\.soundingEndNanoseconds), [50,50])
        XCTAssertNotEqual(tracker.orderedNotes[0].id, tracker.orderedNotes[1].id)
        XCTAssertEqual(tracker.issueCount, 0)
    }

    func testHeldSamePitchReattackIsMarkedAmbiguous() throws {
        var tracker = PianoNoteTracker()
        tracker.process(try input(0x2090_3C64, at: 0))
        tracker.process(try input(0x2090_3C64, at: 10))
        tracker.process(try input(0x2080_3C00, at: 20))
        XCTAssertEqual(tracker.orderedNotes.count, 2)
        XCTAssertTrue(tracker.orderedNotes.allSatisfy(\.isUncertain))
        XCTAssertNil(tracker.orderedNotes[0].keyReleaseNanoseconds)
        XCTAssertEqual(tracker.orderedNotes[1].keyReleaseNanoseconds, 20)
        XCTAssertGreaterThan(tracker.issueCount, 0)
    }

    func testIdenticalPitchesAcrossChannelsEndpointsAndGroupsStayIndependent() throws {
        var tracker = PianoNoteTracker()
        tracker.process(try input(0x2090_3C64, at: 0, endpoint: 1))
        tracker.process(try input(0x2091_3C64, at: 1, endpoint: 1))
        tracker.process(try input(0x2090_3C64, at: 2, endpoint: 2))
        tracker.process(try input(0x2190_3C64, at: 3, endpoint: 1))
        tracker.process(try input(0x2080_3C00, at: 4, endpoint: 1))
        XCTAssertEqual(tracker.orderedNotes.count, 4)
        XCTAssertEqual(tracker.orderedNotes.filter(\.isKeyDown).count, 3)
        XCTAssertEqual(tracker.issueCount, 0)
    }

    func testControllerResetEndsPedalNotesWithoutReleasingHeldKeys() throws {
        var tracker = PianoNoteTracker()
        for (word, time): (UInt32, Int64) in [(0x20B0_407F,0),(0x2090_3C64,10),(0x2080_3C00,20),
                                             (0x2090_4064,30),(0x20B0_7900,40)] {
            tracker.process(try input(word, at: time))
        }
        XCTAssertEqual(tracker.orderedNotes[0].soundingEndNanoseconds, 40)
        XCTAssertTrue(tracker.orderedNotes[1].isKeyDown)
        XCTAssertTrue(tracker.sustainChannels.isEmpty)
    }

    func testAllNotesOffAndSoundOffDoNotInventPhysicalReleases() throws {
        var tracker = PianoNoteTracker()
        tracker.process(try input(0x2090_3C64, at: 0))
        tracker.process(try input(0x20B0_7B00, at: 10))
        XCTAssertTrue(tracker.heldPitches.isEmpty)
        XCTAssertTrue(tracker.orderedNotes[0].isInterrupted)
        XCTAssertNil(tracker.orderedNotes[0].keyReleaseNanoseconds)
        tracker.process(try input(0x2090_4064, at: 20))
        tracker.process(try input(0x20B0_7800, at: 30))
        XCTAssertTrue(tracker.soundingPitches.isEmpty)
        XCTAssertTrue(tracker.orderedNotes[1].isInterrupted)
        XCTAssertNil(tracker.orderedNotes[1].keyReleaseNanoseconds)
    }

    func testAllNotesOffPreservesAlreadyReleasedPedalTone() throws {
        var tracker = PianoNoteTracker()
        for (word, time): (UInt32, Int64) in [(0x20B0_407F,0),(0x2090_3C64,10),(0x2080_3C00,20),(0x20B0_7B00,30)] {
            tracker.process(try input(word, at: time))
        }
        XCTAssertTrue(tracker.orderedNotes[0].isSounding)
        XCTAssertEqual(tracker.issueCount, 0)
        tracker.process(try input(0x20B0_4000, at: 40))
        XCTAssertEqual(tracker.orderedNotes[0].soundingEndNanoseconds, 40)
    }

    func testBentNotesAndTimestampDisorderAreUnverified() throws {
        var tracker = PianoNoteTracker()
        tracker.process(try input(0x20E0_007F, at: 10))
        tracker.process(try input(0x2090_3C64, at: 20))
        tracker.process(try input(0x2080_3C00, at: 15))
        XCTAssertTrue(tracker.orderedNotes[0].isUncertain)
        XCTAssertTrue(tracker.orderedNotes[0].isKeyDown)
        XCTAssertEqual(tracker.issueCount, 1)
    }

    func testTrackerCapsEvidenceAndLiveHistoryCanEvictCompletedNotes() throws {
        var session = PianoNoteTracker(capacity: 2, retainsSessionEvidence: true)
        for (word, time): (UInt32, Int64) in [(0x2090_3C64,0),(0x2080_3C00,1),(0x2090_4064,2),(0x2090_4364,3)] {
            session.process(try input(word, at: time))
        }
        XCTAssertEqual(session.orderedNotes.count, 2)
        XCTAssertEqual(session.droppedCount, 1)
        var live = PianoNoteTracker(capacity: 1)
        live.process(try input(0x2090_3C64, at: 0)); live.process(try input(0x2080_3C00, at: 1))
        live.process(try input(0x2090_4064, at: 2))
        XCTAssertEqual(live.orderedNotes.first?.pitch, MIDIPitch(64))
        XCTAssertEqual(live.droppedCount, 0)
    }

    func testChordMatchingIsIndependentOfArrivalOrder() {
        let group = UUID()
        let expected = [60,64,67].map { expectedNote($0, time: 0, chord: group) }
        let played = [playedNote(67, time: 0), playedNote(60, time: 30_000_000), playedNote(64, time: 10_000_000)]
        let score = PianoEventMatcher().score(pattern: pattern(expected), actual: played)
        XCTAssertEqual(score.correctCount, 3)
        XCTAssertEqual(score.extraCount, 0)
        XCTAssertEqual(Set(score.results.compactMap(\.actualID)).count, 3)
        XCTAssertEqual(score.chords.first?.spreadMilliseconds, 30)
        XCTAssertEqual(score.chords.first?.passes, true)
    }

    func testRepeatedPitchAssignmentUsesBestGlobalPairing() {
        let expected = [expectedNote(60, time: 0), expectedNote(60, time: 40_000_000)]
        let early = playedNote(60, time: -20_000_000), late = playedNote(60, time: 10_000_000)
        let score = PianoEventMatcher().score(pattern: pattern(expected), actual: [late,early])
        XCTAssertEqual(score.correctCount, 2)
        XCTAssertEqual(score.results.first { $0.expectedID == expected[0].id }?.actualID, early.id)
        XCTAssertEqual(score.results.first { $0.expectedID == expected[1].id }?.actualID, late.id)
    }

    func testWrongOctaveMissedExtraAndToleranceBoundary() {
        let expected = [expectedNote(60, time: 0)]
        let wrong = PianoEventMatcher().score(pattern: pattern(expected), actual: [playedNote(72, time: 0)])
        XCTAssertEqual(wrong.results.first?.classification, .wrongPitch)
        XCTAssertEqual(wrong.correctCount, 0)
        let boundary = PianoEventMatcher().score(pattern: pattern(expected), actual: [playedNote(60, time: 100_000_000)])
        XCTAssertEqual(boundary.correctCount, 1)
        let outside = PianoEventMatcher().score(pattern: pattern(expected), actual: [playedNote(60, time: 100_000_001)])
        XCTAssertEqual(Set(outside.results.map(\.classification)), [.missed,.extra])
    }

    func testChordsFailForMissingExtraOrExcessSpread() {
        let group = UUID()
        let expected = [60,64,67].map { expectedNote($0, time: 0, chord: group) }
        for actual in [[playedNote(60, time: 0)],
                       [playedNote(60, time: 0),playedNote(64, time: 0),playedNote(67, time: 0),playedNote(70, time: 0)],
                       [playedNote(60, time: -99_000_000),playedNote(64, time: 0),playedNote(67, time: 99_000_000)]] {
            XCTAssertEqual(PianoEventMatcher().score(pattern: pattern(expected), actual: actual).chords.first?.passes, false)
        }
    }

    func testDurationUsesKeyReleaseAndTimingCorrectionDoesNotChangeHoldTime() {
        let expected = [expectedNote(60, time: 0, duration: 80_000_000)]
        var actual = playedNote(60, time: 30_000_000)
        actual.keyReleaseNanoseconds = 80_000_000
        actual.soundingEndNanoseconds = 900_000_000
        var configuration = PianoScoringConfiguration()
        configuration.gradeDuration = true
        configuration.timingCompensationNanoseconds = 30_000_000
        let score = PianoEventMatcher().score(pattern: pattern(expected), actual: [actual], configuration: configuration)
        XCTAssertEqual(score.results.first?.onsetErrorMilliseconds, 0)
        XCTAssertEqual(score.results.first?.durationErrorMilliseconds, -30)
        XCTAssertEqual(score.results.first?.durationPassed, true)
        actual.keyReleaseNanoseconds = nil
        XCTAssertNil(PianoEventMatcher().score(pattern: pattern(expected), actual: [actual]).results.first?.durationPassed)
    }

    func testUncertainOrDroppedEvidenceCannotBeVerified() {
        var actual = playedNote(60, time: 0)
        actual.isUncertain = true
        let score = PianoEventMatcher().score(pattern: pattern([expectedNote(60, time: 0)]), actual: [actual])
        XCTAssertEqual(score.results.first?.classification, .unverified)
        XCTAssertEqual(score.correctCount, 0)
        XCTAssertFalse(score.isVerified)
        XCTAssertFalse(PianoEventMatcher().score(pattern: pattern([]), actual: [], droppedCount: 1).isVerified)
    }

    func testFloodedChordWindowIsBoundedAndExplicitlyUnverified() {
        let score = PianoEventMatcher().score(pattern: pattern([expectedNote(60, time: 0)]),
                                             actual: (0..<513).map { _ in playedNote(60, time: 0) })
        XCTAssertFalse(score.isVerified)
        XCTAssertEqual(score.correctCount, 0)
        XCTAssertGreaterThan(score.inputIssueCount, 0)
    }

    func testBuiltInExercisesUseValidNotesAndFreshChordGroupsForRepeats() {
        for exercise in PianoExercise.allCases {
            let pattern = PianoPracticePattern.make(exercise: exercise, bpm: 240, repeats: 16)
            XCTAssertTrue(pattern.notes.allSatisfy(\.isValid))
            XCTAssertFalse(pattern.notes.isEmpty)
            XCTAssertTrue(pattern.notes.allSatisfy { $0.onsetNanoseconds + ($0.durationNanoseconds ?? 0) <= pattern.durationNanoseconds })
        }
        let chords = PianoPracticePattern.make(exercise: .chordChanges, bpm: 120, repeats: 2)
        XCTAssertEqual(Set(chords.notes.compactMap(\.chordID)).count, 8)
        XCTAssertEqual(PianoPracticePattern.make(exercise: .cMajorScale, bpm: .nan, repeats: 0).bpm, 120)
    }

    @MainActor
    func testPianoSessionRunsCountInCapturesNotesAndReturnsResults() throws {
        let controller = makeController()
        controller.start(preferences: PianoPracticePreferences(exercise: .cMajorArpeggio, repeats: 1), bpm: 120,
                         configuration: PianoScoringConfiguration())
        XCTAssertEqual(controller.phase, .countIn(8))
        let start = countIn(controller)
        XCTAssertEqual(controller.phase, .running)
        let targets = try XCTUnwrap(controller.pattern).notes
        for note in targets {
            let on = Int64(start) + note.onsetNanoseconds
            let off = on + (note.durationNanoseconds ?? 0)
            controller.receive([try input(wordOn(note.pitch.noteNumber), at: on - 100, hostTime: UInt64(on)),
                                try input(wordOff(note.pitch.noteNumber), at: off - 100, hostTime: UInt64(off))])
        }
        controller.finish()
        XCTAssertEqual(controller.phase, .results)
        XCTAssertEqual(controller.outcome?.correctCount, targets.count)
        XCTAssertEqual(controller.outcome?.medianAbsoluteOnsetErrorMilliseconds, 0)
        XCTAssertEqual(controller.outcome?.isVerified, true)
    }

    @MainActor
    func testSessionCancelDisconnectAndResetNeverCreateResults() throws {
        for operation in 0..<3 {
            let controller = makeController()
            controller.start(preferences: PianoPracticePreferences(), bpm: 120, configuration: PianoScoringConfiguration())
            _ = countIn(controller)
            controller.receive([try input(0x2090_3C64, at: 4_000_001_000, hostTime: 4_000_001_100)])
            switch operation {
            case 0: controller.cancel()
            case 1: controller.inputDisconnected()
            default: controller.resetKeys()
            }
            controller.finish()
            XCTAssertNil(controller.outcome)
            XCTAssertFalse(controller.phase.isActive)
            XCTAssertTrue(controller.input.heldPitches.isEmpty)
        }
    }

    @MainActor
    func testStartRequiresReleasedKeysAndPedalAndIgnoresDuplicateTicks() throws {
        let controller = makeController()
        controller.receive([try input(0x20B0_407F, at: 10, hostTime: 110)])
        controller.start(preferences: PianoPracticePreferences(), bpm: 120, configuration: PianoScoringConfiguration())
        XCTAssertFalse(controller.phase.isActive)
        controller.resetKeys()
        controller.start(preferences: PianoPracticePreferences(), bpm: 120, configuration: PianoScoringConfiguration())
        let tick = MetronomeTick(hostTime: 1_000, beat: 1, isAccent: true)
        controller.handleTick(tick); controller.handleTick(tick)
        XCTAssertEqual(controller.phase, .countIn(7))
        controller.cancel()
    }

    @MainActor
    func testChannelFilterDoesNotGradeOtherChannelAndStaleInputIsIgnored() throws {
        let controller = makeController()
        controller.start(preferences: PianoPracticePreferences(channel: 2), bpm: 120, configuration: PianoScoringConfiguration())
        controller.receive([try input(0x2090_3C64, at: 10, hostTime: 110),
                            try input(0x2091_4064, at: 20, hostTime: 120),
                            try input(0x2091_4364, at: -99, hostTime: 1)])
        XCTAssertEqual(controller.input.orderedNotes.count, 1)
        XCTAssertEqual(controller.input.orderedNotes.first?.pitch, MIDIPitch(64))
        controller.cancel()
    }

    @MainActor
    func testInvalidSettingsCannotStartOrOverflowDeadline() {
        let controller = makeController()
        var configuration = PianoScoringConfiguration()
        configuration.timingCompensationNanoseconds = .min
        controller.start(preferences: PianoPracticePreferences(), bpm: 120, configuration: configuration)
        XCTAssertFalse(controller.phase.isActive)
        XCTAssertNil(controller.pattern)
    }

    @MainActor
    func testAppRoutesPianoInputAndSwitchingCancelsWithoutDrumHistory() async throws {
        let state = makeState()
        state.selectInstrument(.electricPiano)
        state.selectedMIDIInputID = 42
        state.midiStatus = .connected("Keyboard")
        state.startPianoPractice()
        _ = countIn(state.piano)
        await state.handleMIDIBatch(MIDIMessageBatch(events: [try message(0x2090_3C64, hostTime: 4_000_001_000)],
            endpointID: 42, endpointName: "Keyboard", connectionGeneration: 0, droppedCount: 0))
        XCTAssertEqual(state.piano.input.orderedNotes.count, 1)
        state.selectInstrument(.drums)
        state.piano.finish()
        XCTAssertNil(state.piano.outcome)
        XCTAssertFalse(state.piano.phase.isActive)
        XCTAssertTrue(state.practiceHistory.isEmpty)
    }

    @MainActor
    func testAppRejectsStaleConnectionBatchAndKeepsDrumMIDIBehavior() async throws {
        let state = makeState()
        state.selectedMIDIInputID = 42
        await state.handleMIDIBatch(MIDIMessageBatch(events: [try message(0x2099_2668, hostTime: 1_000)],
            endpointID: 42, endpointName: "Module", connectionGeneration: 0, droppedCount: 0))
        XCTAssertEqual(state.events.first?.voice, .snare)
        state.selectInstrument(.electricPiano)
        state.selectedMIDIInputID = 42
        await state.handleMIDIBatch(MIDIMessageBatch(events: [try message(0x2090_3C64, hostTime: 1_000)],
            endpointID: 42, endpointName: "Keyboard", connectionGeneration: 99, droppedCount: 0))
        XCTAssertTrue(state.piano.input.orderedNotes.isEmpty)
    }

    @MainActor
    func testZeroTimestampUsesCaptureTimeAndCannotCrossInstrumentBoundary() async throws {
        let state = makeState()
        state.selectInstrument(.electricPiano)
        state.selectedMIDIInputID = 42
        let note = try message(0x2090_3C64, hostTime: 0)
        await state.handleMIDIBatch(MIDIMessageBatch(events: [note], endpointID: 42, endpointName: "Keyboard",
            connectionGeneration: 0, droppedCount: 0, receivedHostTime: 1))
        XCTAssertTrue(state.piano.input.orderedNotes.isEmpty)
        await state.handleMIDIBatch(MIDIMessageBatch(events: [note], endpointID: 42, endpointName: "Keyboard",
            connectionGeneration: 0, droppedCount: 0, receivedHostTime: 150))
        XCTAssertEqual(state.piano.input.orderedNotes.first?.onsetHostTime, 150)
        XCTAssertEqual(state.piano.input.orderedNotes.first?.onsetNanoseconds, 50)
        XCTAssertEqual(state.piano.recentMessages.first?.message.hostTime, 0)
    }

    @MainActor
    func testChangingPianoExerciseOrTempoClearsPreviousResults() {
        let state = makeState()
        state.selectInstrument(.electricPiano)
        state.selectedMIDIInputID = 42
        state.midiStatus = .connected("Keyboard")
        state.startPianoPractice()
        _ = countIn(state.piano)
        state.piano.finish()
        XCTAssertNotNil(state.piano.outcome)
        state.updatePianoPreferences { $0.exercise = .chordChanges }
        XCTAssertNil(state.piano.outcome)
        XCTAssertNil(state.piano.pattern)
        state.startPianoPractice()
        _ = countIn(state.piano)
        state.piano.finish()
        state.practiceBPM = 85
        XCTAssertNil(state.piano.outcome)
    }

    @MainActor
    func testPianoPreferencesRoundTripAndDurationSettingsStaySeparate() throws {
        let state = makeState()
        state.selectInstrument(.electricPiano)
        state.updatePianoPreferences { $0.exercise = .chordChanges; $0.channel = 2; $0.gradeDuration = true; $0.repeats = 3 }
        let data = try PracticeDataArchive.decodeAndValidate(state.exportPracticeData())
        let preferences = try XCTUnwrap(data.instrumentProfiles.first { $0.instrument == .electricPiano }?.pianoPractice)
        XCTAssertEqual(preferences, state.pianoPreferences)
        XCTAssertEqual(preferences.channel, 2)
        XCTAssertTrue(preferences.gradeDuration)
        XCTAssertNil(data.instrumentProfiles.first { $0.instrument == .drums }?.pianoPractice)
        state.selectInstrument(.drums); state.selectInstrument(.electricPiano)
        XCTAssertEqual(state.pianoPreferences, preferences)
    }

    @MainActor
    func testPianoAndDrumAlignmentProfilesCannotShareCorrections() {
        let defaults = makeDefaults()
        let timingStore = UserDefaultsTimingAlignmentStore(defaults: defaults)
        for (id, correction) in [("42",10.0),("electricPiano:42",30.0)] {
            timingStore.saveProfile(TimingAlignmentProfile(id: UUID(), source: .midi, inputID: id, inputName: "Keyboard",
                outputUID: "system-default", outputName: "System Default", voice: .unknown,
                compensationMilliseconds: correction, medianAbsoluteDeviationMilliseconds: 1, sampleCount: 12, createdAt: Date()))
        }
        let state = AppState(clock: FixedHostClock(hostTime: 100), converter: LinearHostTimeConverter(),
            timingAlignmentStore: timingStore, practiceDataStore: UserDefaultsPracticeDataStore(defaults: defaults),
            metronomeEngine: PianoTestMetronome(), userPreferences: defaults)
        state.midiDevices = [MIDIInputDevice(id: 42, endpoint: 42, name: "Keyboard")]
        state.selectedMIDIInputID = 42
        XCTAssertEqual(state.activeTimingAlignmentProfile?.compensationMilliseconds, 10)
        state.selectInstrument(.electricPiano); state.selectedMIDIInputID = 42
        XCTAssertEqual(state.activeTimingAlignmentProfile?.compensationMilliseconds, 30)
        XCTAssertEqual(state.activeTimingAlignmentProfile?.scopeDisplayName, "Piano MIDI")
    }

    @MainActor
    func testStaticPianoRollAndKeyboardRender() throws {
        let pattern = PianoPracticePattern.make(exercise: .chordChanges, bpm: 120, repeats: 1)
        let view = VStack(spacing: 20) {
            Text("Electric Piano — C–F–G chord changes").font(.title)
            PianoRollView(pattern: pattern, playheadNanoseconds: 500_000_000)
            PianoKeyboardView(held: [MIDIPitch(60)!,MIDIPitch(64)!,MIDIPitch(67)!], sounding: [MIDIPitch(60)!,MIDIPitch(64)!,MIDIPitch(67)!])
        }.padding(24).frame(width: 980, height: 530).background(Color(nsColor: .windowBackgroundColor))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        let bitmap = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: "/private/tmp/drumApp-phase2-piano-preview.png"))
        XCTAssertEqual(bitmap.pixelsWide, 980)
    }

    private func message(_ word: UInt32, hostTime: UInt64 = 1) throws -> MIDIChannelEvent {
        try XCTUnwrap(MIDI1UMPParser.channelEvent(from: word, hostTime: hostTime))
    }
    private func input(_ word: UInt32, at time: Int64, endpoint: Int32 = 42, hostTime: UInt64 = 1) throws -> PianoInputEvent {
        PianoInputEvent(message: try message(word, hostTime: hostTime), endpointID: endpoint,
                        sessionTimeNanoseconds: time, effectiveHostTime: hostTime)
    }
    private func wordOn(_ pitch: UInt8) -> UInt32 { 0x2090_0064 | UInt32(pitch) << 8 }
    private func wordOff(_ pitch: UInt8) -> UInt32 { 0x2080_0000 | UInt32(pitch) << 8 }
    private func expectedNote(_ pitch: Int, time: Int64, duration: Int64? = nil, chord: UUID? = nil) -> PitchedExpectedNote {
        PitchedExpectedNote(pitch: MIDIPitch(pitch)!, onsetNanoseconds: time, durationNanoseconds: duration, chordID: chord)
    }
    private func playedNote(_ pitch: Int, time: Int64) -> PianoPlayedNote {
        PianoPlayedNote(id: UUID(), input: PianoChannelIdentity(endpointID: 42, group: 0, channel: 1), pitch: MIDIPitch(pitch)!,
                        velocity: 100, onsetHostTime: 1, onsetNanoseconds: time)
    }
    private func pattern(_ notes: [PitchedExpectedNote]) -> PianoPracticePattern {
        PianoPracticePattern(exercise: .cMajorArpeggio, bpm: 120, notes: notes, durationNanoseconds: 1_000_000_000)
    }
    @MainActor private func makeController() -> PianoPracticeController {
        PianoPracticeController(clock: FixedHostClock(hostTime: 100),
            timeline: SessionTimeline(originHostTime: 100, converter: LinearHostTimeConverter()))
    }
    @MainActor @discardableResult private func countIn(_ controller: PianoPracticeController) -> UInt64 {
        for beat in 0..<9 {
            controller.handleTick(MetronomeTick(hostTime: UInt64(1_000 + beat * 500_000_000), beat: beat % 4 + 1, isAccent: beat % 4 == 0))
        }
        return 4_000_001_000
    }
    private func makeDefaults() -> UserDefaults {
        let suite = "PianoCoreTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }
    @MainActor private func makeState() -> AppState {
        let defaults = makeDefaults()
        return AppState(clock: FixedHostClock(hostTime: 100), converter: LinearHostTimeConverter(),
            practiceDataStore: UserDefaultsPracticeDataStore(defaults: defaults),
            metronomeEngine: PianoTestMetronome(), userPreferences: defaults)
    }
}

private final class PianoBatchCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var batch: MIDIMessageBatch?
    func set(_ batch: MIDIMessageBatch) { lock.withLock { self.batch = batch } }
    func get() -> MIDIMessageBatch? { lock.withLock { batch } }
}

private final class PianoTestMetronome: MetronomeControlling {
    func startMonitoring() {}
    func select(deviceID: AudioDeviceID?) {}
    func start(bpm: Double) {}
    func stop() {}
    func rebuildAudioGraph(completion: @escaping @Sendable () -> Void) { completion() }
    func updateBPM(_ bpm: Double) {}
    func updateSound(_ sound: MetronomeSound) {}
    func updateGainDecibels(_ gain: Double) {}
    func updateLimiter(enabled: Bool, ceilingDBFS: Double) {}
    func updateKickMonitoring(enabled: Bool, sound: KickMonitorSound, gainDecibels: Double,
                              velocitySensitive: Bool, retriggerMilliseconds: Double, startAudioIfNeeded: Bool) {}
    func triggerKick(velocity: Double, eventHostTime: UInt64, respectsRetriggerLockout: Bool) {}
    func followTempoMap(startPresentationHostTime: UInt64, referenceBeats: [PracticeReferenceBeat]) {}
}
