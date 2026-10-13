import CryptoKit
import Foundation

enum PianoPracticeMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case builtIn, custom, imported
    var id: String { rawValue }
    var displayName: String { switch self { case .builtIn: "Built-in"; case .custom: "Custom / sequence"; case .imported: "MIDI song" } }
}

struct InstrumentRecordingPreferences: Codable, Equatable, Sendable {
    var enabled = false
    var inputUID: String?
    var channels: PracticeAudioChannelSelection = .input1
    var isValid: Bool { (inputUID?.count ?? 0) <= 1_024 }
}

struct PianoAuthoredNote: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var pitch: MIDIPitch
    var slot: Int
    var length: Int
    var part: NotePart?
}

struct PianoMeasureDefinition: Codable, Equatable, Sendable {
    var name = "My measure"
    var slots = 16
    var notes: [PianoAuthoredNote] = []
    var isValid: Bool {
        name.count <= 1_024 && [8,12,16].contains(slots) && notes.count <= 512
            && Set(notes.map(\.id)).count == notes.count
            && Set(notes.map { "\($0.slot):\($0.pitch.noteNumber)" }).count == notes.count
            && notes.allSatisfy { (0..<slots).contains($0.slot) && (1...(slots - $0.slot)).contains($0.length) }
    }
}

struct PianoSequenceStep: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var measure: PianoMeasureDefinition
    var repeats = 1
}

struct PianoExerciseDefinition: Codable, Equatable, Sendable {
    var name = "My piano exercise"
    var steps: [PianoSequenceStep] = [PianoSequenceStep(measure: PianoMeasureDefinition())]
    var isValid: Bool {
        name.count <= 1_024 && !steps.isEmpty && steps.count <= 32 && Set(steps.map(\.id)).count == steps.count
            && steps.allSatisfy { $0.measure.isValid && (1...16).contains($0.repeats) }
            && steps.reduce(0) { $0 + $1.repeats } <= 128
            && steps.reduce(0) { $0 + $1.repeats * $1.measure.notes.count } <= 10_000
    }
    var isPlayable: Bool { isValid && steps.contains { !$0.measure.notes.isEmpty } }
    func pattern(bpm: Double, repeats: Int) throws -> PianoPracticePattern {
        guard isPlayable, (40...240).contains(bpm), (1...16).contains(repeats),
              steps.reduce(0, { $0 + $1.repeats }) * repeats <= 128,
              steps.reduce(0, { $0 + $1.repeats * $1.measure.notes.count }) * repeats <= 10_000 else {
            throw PianoWorkflowError.invalid("Add notes and keep the exercise within 128 measures and 10,000 notes, including repeats.")
        }
        let beat = Int64((60_000_000_000 / bpm).rounded())
        var notes: [PitchedExpectedNote] = [], beats: [PracticeReferenceBeat] = []
        var measureIndex = 0
        for _ in 0..<repeats {
            for step in steps {
                for _ in 0..<step.repeats {
                    let offset = Int64(measureIndex) * beat * 4
                    for b in 0..<4 { beats.append(PracticeReferenceBeat(offsetNanoseconds: offset + Int64(b) * beat,
                        measure: measureIndex + 1, beat: b + 1, isAccent: b == 0)) }
                    for (slot, group) in Dictionary(grouping: step.measure.notes, by: \.slot).sorted(by: { $0.key < $1.key }) {
                        let chordID = group.count > 1 ? UUID() : nil
                        for note in group.sorted(by: { $0.pitch.noteNumber < $1.pitch.noteNumber }) {
                            notes.append(PitchedExpectedNote(pitch: note.pitch, onsetNanoseconds: offset + Int64(slot) * beat * 4 / Int64(step.measure.slots),
                                durationNanoseconds: Int64(note.length) * beat * 4 / Int64(step.measure.slots), chordID: chordID, part: note.part))
                        }
                    }
                    measureIndex += 1
                }
            }
        }
        return PianoPracticePattern(exercise: .cMajorScale, bpm: bpm, notes: notes, durationNanoseconds: Int64(measureIndex) * beat * 4,
            title: name.isEmpty ? "Custom piano exercise" : name, sourceKey: "custom:\(fingerprint):\(repeats)", referenceBeats: beats)
    }
    var fingerprint: String {
        // Exclude editor UUIDs; the musical content defines the progression scope.
        let content = steps.map { step in
            "\(step.repeats):\(step.measure.slots):" + step.measure.notes.sorted { ($0.slot, $0.pitch.noteNumber) < ($1.slot, $1.pitch.noteNumber) }
                .map { "\($0.pitch.noteNumber),\($0.slot),\($0.length),\(String(describing: $0.part))" }.joined(separator: ";")
        }.joined(separator: "|")
        return SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct PianoSavedExercise: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var definition: PianoExerciseDefinition
    var createdAt = Date()
    var updatedAt = Date()
}

struct PianoImportedSong: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var source: ImportedSong
    var trackIndices: [Int]
    var channels: [UInt8] // UI and live input use 1...16; SMF stores 0...15.
    var createdAt = Date()
    var updatedAt = Date()
    init(source: ImportedSong) {
        self.source = source
        let melodic = source.tracks.filter { $0.notes.contains { $0.channel != 9 } }
        let track = melodic.max(by: { $0.notes.count < $1.notes.count }) ?? source.selectedTrack!
        trackIndices = [track.index]
        channels = Array(Set(track.notes.filter { $0.channel != 9 }.map { $0.channel + 1 })).sorted()
        if channels.isEmpty { channels = Array(Set(track.notes.map { $0.channel + 1 })).sorted() }
    }
    var isValid: Bool {
        source.name.count <= 1_024 && (1...32_767).contains(source.ticksPerQuarterNote)
            && source.tracks.count <= 256 && !source.tracks.isEmpty
            && Set(source.tracks.map(\.index)).count == source.tracks.count
            && source.tracks.reduce(0, { $0 + $1.notes.count }) <= 250_000
            && source.tracks.allSatisfy { $0.notes.allSatisfy { note in
                (0...100_000_000).contains(note.tick) && note.noteNumber < 128 && note.velocity > 0 && note.velocity < 128 && note.channel < 16
                    && (note.durationTicks.map { $0 >= 0 && $0 <= 100_000_000 - note.tick } ?? true)
            } && ($0.controls?.count ?? 0) <= 250_000 && ($0.controls?.allSatisfy(\.isValid) ?? true) }
            && source.tempoChanges.count <= 10_000 && source.timeSignatureChanges.count <= 10_000
            && source.tempoChanges.allSatisfy { (0...100_000_000).contains($0.tick) && (1...16_777_215).contains($0.microsecondsPerQuarterNote) }
            && source.timeSignatureChanges.allSatisfy { (0...100_000_000).contains($0.tick) && (1...128).contains($0.numerator) && [1,2,4,8,16,32,64].contains($0.denominator) }
            && trackIndices.count <= 256 && Set(trackIndices).count == trackIndices.count
            && trackIndices.allSatisfy { index in source.tracks.contains { $0.index == index } }
            && Set(channels).count == channels.count && channels.allSatisfy { (1...16).contains($0) }
    }
    var timelineSong: ImportedSong {
        var song = source
        // Include the final release in measure geometry without changing the drum timeline.
        let end = source.tracks.flatMap(\.notes).map { $0.tick + ($0.durationTicks ?? 0) }.max() ?? 0
        if end > 0 {
            song = ImportedSong(id: source.id, name: source.name, sourceFilename: source.sourceFilename, format: source.format,
                ticksPerQuarterNote: source.ticksPerQuarterNote, tempoChanges: source.tempoChanges, timeSignatureChanges: source.timeSignatureChanges,
                tracks: source.tracks + [ImportedMIDITrack(index: -1, name: "Duration boundary", notes: [ImportedMIDINoteEvent(tick: end - 1, noteNumber: 60, velocity: 1, channel: 0)])],
                selectedTrackIndex: source.selectedTrackIndex, noteMappings: source.noteMappings)
        }
        return song
    }
    var measures: [ImportedSongMeasure] { ImportedSongTimeline.measures(for: timelineSong) }
    func pattern(bpm: Double, start: Int, end: Int, repeats: Int, transpose: Int) throws -> PianoPracticePattern {
        let measures = self.measures
        guard isValid, (40...240).contains(bpm), (1...16).contains(repeats), (-24...24).contains(transpose),
              start >= 1, end >= start, end <= measures.count, (end - start + 1) * repeats <= 128 else {
            throw PianoWorkflowError.invalid("Choose a valid section, up to 128 measures including repeats.")
        }
        let first = measures[start - 1].startTick, last = measures[end - 1].endTick
        let scale = ImportedSongTimeline.bpm(at: first, song: source) / bpm
        func offset(_ tick: Int64) throws -> Int64 {
            let value = Double(ImportedSongTimeline.nanoseconds(from: first, to: tick, song: source)) * scale
            guard value.isFinite, (0...3_600_000_000_000).contains(value) else { throw PianoWorkflowError.invalid("This section is longer than one hour.") }
            return Int64(value.rounded())
        }
        let duration = try offset(last)
        guard duration > 0, duration <= 3_600_000_000_000 / Int64(repeats) else { throw PianoWorkflowError.invalid("This section is too long.") }
        let tracks = source.tracks.filter { trackIndices.contains($0.index) }
        let selected = tracks.flatMap(\.notes).filter { channels.contains($0.channel + 1) && $0.tick >= first && $0.tick < last }
        guard !selected.isEmpty, selected.count * repeats <= 10_000 else { throw PianoWorkflowError.invalid("Select a part containing 1–10,000 notes including repeats.") }
        var notes: [PitchedExpectedNote] = [], beats: [PracticeReferenceBeat] = []
        for iteration in 0..<repeats {
            let base = Int64(iteration) * duration
            for (tick, group) in Dictionary(grouping: selected, by: \.tick).sorted(by: { $0.key < $1.key }) {
                let pitches = Dictionary(grouping: group, by: \.noteNumber)
                let chordID = pitches.count > 1 ? UUID() : nil
                for (value, duplicates) in pitches.sorted(by: { $0.key < $1.key }) {
                    guard let pitch = MIDIPitch(Int(value) + transpose) else { throw PianoWorkflowError.invalid("Transposition moves a note outside MIDI's pitch range.") }
                    let onset = try offset(tick)
                    let lengths = try duplicates.compactMap { note -> Int64? in
                        guard let length = note.durationTicks, note.durationUncertain != true else { return nil }
                        return try offset(min(tick + length, last)) - onset
                    }
                    notes.append(PitchedExpectedNote(pitch: pitch, onsetNanoseconds: base + onset,
                        durationNanoseconds: lengths.count == duplicates.count ? lengths.max() : nil, chordID: chordID))
                }
            }
            for index in (start - 1)..<end {
                let m = measures[index], ticksPerBeat = max(Int64(source.ticksPerQuarterNote) * 4 / Int64(m.denominator), 1)
                for b in 0..<m.numerator {
                    let tick = m.startTick + Int64(b) * ticksPerBeat
                    if tick < m.endTick { beats.append(PracticeReferenceBeat(offsetNanoseconds: base + (try offset(tick)),
                        measure: iteration * (end - start + 1) + index - start + 2, beat: b + 1, isAccent: b == 0)) }
                }
            }
        }
        let bent = tracks.contains { track in
            let relevant = (track.controls ?? []).filter { channels.contains($0.channel + 1) && $0.kind == .pitchBend }
            return channels.contains { channel in
                relevant.last(where: { $0.channel + 1 == channel && $0.tick <= first })?.value != nil
                    && relevant.last(where: { $0.channel + 1 == channel && $0.tick <= first })?.value != 8192
            } || relevant.contains { $0.tick >= first && $0.tick < last && $0.value != 8192 }
        }
        let warning = "Notes already held at the section start are omitted. Release section-ending notes at the loop boundary. Duplicate unison notes share one key. Missing releases have no duration target." + (bent ? " This part contains pitch bends; tempo progress is unverified." : "")
        return PianoPracticePattern(exercise: .cMajorScale, bpm: bpm, notes: notes, durationNanoseconds: duration * Int64(repeats),
            title: "\(source.name) • measures \(start)–\(end)",
            sourceKey: "song:\(id):\(trackIndices.sorted()):\(channels.sorted()):\(start):\(end):\(repeats):\(transpose)",
            referenceBeats: beats, referenceVerified: !bent, warning: warning)
    }
}

struct PianoProgressionSettings: Codable, Equatable, Sendable {
    var advance = false
    var ceiling = false
    var stepBPM = 5.0
    var cleanRuns = 3
    var isValid: Bool { (1...20).contains(stepBPM) && (1...10).contains(cleanRuns) && !(advance && ceiling) }
}

struct PianoTempoRecord: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var name: String
    var highestCleanBPM: Double?
    var streak = 0
    var lastBPM: Double
    var updatedAt = Date()
}

struct PianoCeilingRun: Codable, Equatable, Sendable {
    var key: String
    var name: String
    var stepBPM: Double
    var highestCleanBPM: Double?
    var phase: CeilingRunPhase
    var sessionIDs: [UUID] = []
    var updatedAt = Date()
}

struct PianoSessionRecord: Identifiable, Codable, Equatable, Sendable {
    var id: UUID
    var instrument: InstrumentKind = .electricPiano
    var completedAt = Date()
    var updatedAt = Date()
    var outcome: PianoPracticeOutcome
    var rawEvents: [PianoInputEvent]
    var devices: PracticeSessionDeviceContext
    var recording: InstrumentRecordingPreferences
    var progressionKey: String
    var scoringVersion = 1
    var notes = ""
    var tags: [String] = []
    var isValid: Bool {
        instrument == .electricPiano && outcome.pattern.isValid && outcome.configuration.isValid
            && outcome.actualNotes.count <= 10_000 && outcome.results.count <= 20_000 && outcome.chords.count <= 10_000
            && rawEvents.count <= 20_000 && notes.count <= 100_000 && tags.count <= 100 && tags.allSatisfy { $0.count <= 1_024 }
            && recording.isValid && progressionKey.hasPrefix("electricPiano:") && progressionKey.count <= 2_048
            && outcome.droppedCount >= 0 && outcome.inputIssueCount >= 0
            && Set(outcome.actualNotes.map(\.id)).count == outcome.actualNotes.count
            && Set(outcome.results.map(\.id)).count == outcome.results.count
            && outcome.actualNotes.allSatisfy { (1...16).contains($0.input.channel) && $0.input.group < 16 && $0.velocity > 0 && $0.velocity < 128
                && (-2_000_000_000...3_602_000_000_000).contains($0.onsetNanoseconds) }
            && outcome.actualNotes.allSatisfy { n in (n.keyReleaseNanoseconds.map { $0 >= n.onsetNanoseconds && $0 <= 3_602_000_000_000 } ?? true)
                && (n.soundingEndNanoseconds.map { $0 >= n.onsetNanoseconds && $0 <= 3_602_000_000_000 } ?? true) }
            && evidenceReferencesAreValid
    }
    private var evidenceReferencesAreValid: Bool {
        let expected = Set(outcome.pattern.notes.map(\.id)), actual = Set(outcome.actualNotes.map(\.id))
        let resultExpected = outcome.results.compactMap(\.expectedID), resultActual = outcome.results.compactMap(\.actualID)
        guard Set(resultExpected) == expected, Set(resultActual) == actual,
              Set(resultExpected).count == resultExpected.count, Set(resultActual).count == resultActual.count else { return false }
        return outcome.results.allSatisfy { result in
            [result.onsetErrorMilliseconds, result.durationErrorMilliseconds].compactMap { $0 }.allSatisfy { $0.isFinite && abs($0) <= 3_602_000 }
        } && Set(outcome.chords.map(\.id)) == Set(outcome.pattern.notes.compactMap(\.chordID))
    }
}

struct PianoWorkflowArchive: Codable, Equatable, Sendable {
    var exercises: [PianoSavedExercise] = []
    var songs: [PianoImportedSong] = []
    var sessions: [PianoSessionRecord] = []
    var tempos: [PianoTempoRecord] = []
    var ceiling: PianoCeilingRun?
    var isValid: Bool {
        exercises.count <= 1_000 && songs.count <= 500 && sessions.count <= 2_000 && tempos.count <= 2_000
            && Set(exercises.map(\.id)).count == exercises.count && Set(songs.map(\.id)).count == songs.count
            && Set(sessions.map(\.id)).count == sessions.count && Set(tempos.map(\.id)).count == tempos.count
            && exercises.allSatisfy { $0.definition.isPlayable } && songs.allSatisfy(\.isValid) && sessions.allSatisfy(\.isValid)
            && tempos.allSatisfy { $0.id.hasPrefix("electricPiano:") && $0.id.count <= 2_048 && $0.name.count <= 1_024
                && (40...240).contains($0.lastBPM) && ($0.highestCleanBPM.map { (40...240).contains($0) } ?? true) && (0...10).contains($0.streak) }
            && (ceiling.map { run in
                run.key.hasPrefix("electricPiano:") && run.key.count <= 2_048 && (1...20).contains(run.stepBPM)
                    && run.sessionIDs.count <= 200 && Set(run.sessionIDs).count == run.sessionIDs.count
                    && Set(run.sessionIDs).isSubset(of: Set(sessions.map(\.id)))
                    && (run.highestCleanBPM.map { (40...240).contains($0) } ?? true)
                    && { switch run.phase {
                    case let .testing(bpm), let .readyForNext(bpm): return (40...240).contains(bpm)
                    case let .found(highest, failed): return (highest.map { (40...240).contains($0) } ?? true) && (failed.map { (40...240).contains($0) } ?? true)
                    } }()
            } ?? true)
    }
}

enum PianoWorkflowError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { switch self { case let .invalid(message): message } }
}
