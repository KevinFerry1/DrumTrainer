import Foundation

struct PianoInputEvent: Codable, Equatable, Sendable {
    let message: MIDIChannelEvent
    let endpointID: Int32
    let sessionTimeNanoseconds: Int64
    let effectiveHostTime: UInt64
}

struct PianoChannelIdentity: Hashable, Codable, Sendable {
    let endpointID: Int32
    let group: UInt8
    let channel: UInt8
}

struct PianoKeyIdentity: Hashable, Sendable {
    let input: PianoChannelIdentity
    let pitch: MIDIPitch
}

struct PianoPlayedNote: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let input: PianoChannelIdentity
    let pitch: MIDIPitch
    let velocity: UInt8
    let onsetHostTime: UInt64
    let onsetNanoseconds: Int64
    var keyReleaseNanoseconds: Int64?
    var soundingEndNanoseconds: Int64?
    var isUncertain = false
    var isInterrupted = false

    var isKeyDown: Bool { keyReleaseNanoseconds == nil && !isInterrupted }
    var isSounding: Bool { soundingEndNanoseconds == nil && !isInterrupted }
}

struct PianoScoringConfiguration: Codable, Equatable, Sendable {
    var gradeDuration = false
    var onsetToleranceNanoseconds: Int64 = 100_000_000
    var durationToleranceNanoseconds: Int64 = 150_000_000
    var chordSpreadToleranceNanoseconds: Int64 = 80_000_000
    var timingCompensationNanoseconds: Int64 = 0
    var isValid: Bool {
        (1...500_000_000).contains(onsetToleranceNanoseconds)
            && (0...1_000_000_000).contains(durationToleranceNanoseconds)
            && (0...500_000_000).contains(chordSpreadToleranceNanoseconds)
            && (-1_000_000_000...1_000_000_000).contains(timingCompensationNanoseconds)
    }
}

struct PianoPracticePreferences: Codable, Equatable, Sendable {
    var exercise: PianoExercise = .cMajorScale
    var repeats: Int = 2
    var channel: UInt8?
    var gradeDuration = false
    var mode: PianoPracticeMode?
    var draft: PianoExerciseDefinition?
    var customExerciseID: UUID?
    var importedSongID: UUID?
    var sectionStart: Int?
    var sectionEnd: Int?
    var transposition: Int?
    var progression: PianoProgressionSettings?
    var effectiveMode: PianoPracticeMode { mode ?? .builtIn }

    var isValid: Bool {
        (draft?.isValid ?? true) && (progression?.isValid ?? true)
            && (1...20_000).contains(sectionStart ?? 1)
            && ((sectionStart ?? 1)...20_000).contains(sectionEnd ?? sectionStart ?? 1)
            && (-24...24).contains(transposition ?? 0)
            && (1...16).contains(repeats) && (channel.map { (1...16).contains($0) } ?? true)
    }
}

enum PianoExercise: String, CaseIterable, Codable, Identifiable, Sendable {
    case cMajorScale, aMinorScale, cMajorArpeggio, chordChanges, twoHandOctaves
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .cMajorScale: "C major scale"
        case .aMinorScale: "A minor scale"
        case .cMajorArpeggio: "C major arpeggio"
        case .chordChanges: "C–F–G chord changes"
        case .twoHandOctaves: "Two-hand octave coordination"
        }
    }
    var guide: String {
        switch self {
        case .cMajorScale: "C4 to C5 and back, one note per beat."
        case .aMinorScale: "A3 to A4 and back, one note per beat."
        case .cMajorArpeggio: "C4, E4, G4, C5 and back, one note per beat."
        case .chordChanges: "C major, F major, G major, C major. Play each chord together and hold for two beats."
        case .twoHandOctaves: "Play C3/C4, D3/D4, E3/E4, F3/F4, then return, with both hands together."
        }
    }
}

struct PianoPracticePattern: Codable, Equatable, Sendable {
    let exercise: PianoExercise
    let bpm: Double
    let notes: [PitchedExpectedNote] // Relative to the audible exercise start.
    let durationNanoseconds: Int64

    var title: String?
    var sourceKey: String?
    var referenceBeats: [PracticeReferenceBeat]?
    var referenceVerified: Bool?
    var warning: String?
    var displayName: String { title ?? exercise.displayName }

    var isValid: Bool {
        bpm.isFinite && (40...240).contains(bpm) && (1...3_600_000_000_000).contains(durationNanoseconds)
            && !notes.isEmpty && notes.count <= 10_000 && Set(notes.map(\.id)).count == notes.count
            && notes.allSatisfy { $0.isValid && $0.onsetNanoseconds >= 0 && $0.onsetNanoseconds < durationNanoseconds
 }
            && notes.allSatisfy { note in (note.durationNanoseconds ?? 0) <= durationNanoseconds - note.onsetNanoseconds }
            && (referenceBeats?.count ?? 0) <= 20_000
            && (referenceBeats?.allSatisfy { $0.offsetNanoseconds >= 0 && $0.offsetNanoseconds < durationNanoseconds
                && (1...128).contains($0.measure) && (1...128).contains($0.beat) } ?? true)
            && (title?.count ?? 0) <= 1_024 && (sourceKey?.count ?? 0) <= 1_024 && (warning?.count ?? 0) <= 10_000
    }

    static func make(exercise: PianoExercise, bpm: Double, repeats: Int) -> PianoPracticePattern {
        let bpm = bpm.isFinite ? min(max(bpm, 40), 240) : 120
        let beat = Int64((60_000_000_000 / bpm).rounded())
        let pitches: [[Int]]
        let beatsPerAttack: Int64
        switch exercise {
        case .cMajorScale: pitches = [60,62,64,65,67,69,71,72,71,69,67,65,64,62,60,60].map { [$0] }; beatsPerAttack = 1
        case .aMinorScale: pitches = [57,59,60,62,64,65,67,69,67,65,64,62,60,59,57,57].map { [$0] }; beatsPerAttack = 1
        case .cMajorArpeggio: pitches = [60,64,67,72,67,64,60,60].map { [$0] }; beatsPerAttack = 1
        case .chordChanges: pitches = [[60,64,67],[60,65,69],[59,62,67],[60,64,67]]; beatsPerAttack = 2
        case .twoHandOctaves: pitches = [[48,60],[50,62],[52,64],[53,65],[53,65],[52,64],[50,62],[48,60]]; beatsPerAttack = 1
        }
        let totalAttacks = pitches.count * min(max(repeats, 1), 16)
        var notes: [PitchedExpectedNote] = []
        for attack in 0..<totalAttacks {
            let chord = pitches[attack % pitches.count]
            let group = chord.count > 1 ? UUID() : nil
            for (index, value) in chord.enumerated() {
                notes.append(PitchedExpectedNote(pitch: MIDIPitch(value)!, onsetNanoseconds: Int64(attack) * beatsPerAttack * beat,
                    durationNanoseconds: beatsPerAttack * beat * 4 / 5, chordID: group,
                    part: exercise == .twoHandOctaves ? (index == 0 ? .leftHand : .rightHand) : nil))
            }
        }
        return PianoPracticePattern(exercise: exercise, bpm: bpm, notes: notes,
                                    durationNanoseconds: Int64(totalAttacks) * beatsPerAttack * beat)
    }
}

enum PianoMatchClassification: String, Codable, Sendable {
    case correct, wrongPitch, missed, extra, unverified
}

struct PianoNoteResult: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let expectedID: UUID?
    let actualID: UUID?
    let expectedPitch: MIDIPitch?
    let actualPitch: MIDIPitch?
    let classification: PianoMatchClassification
    let onsetErrorMilliseconds: Double?
    let durationErrorMilliseconds: Double?
    let durationPassed: Bool?
}

struct PianoChordResult: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let expectedCount: Int
    let correctCount: Int
    let spreadMilliseconds: Double?
    let passes: Bool
}

struct PianoPracticeOutcome: Codable, Equatable, Sendable {
    let pattern: PianoPracticePattern
    let actualNotes: [PianoPlayedNote]
    let results: [PianoNoteResult]
    let chords: [PianoChordResult]
    let configuration: PianoScoringConfiguration
    let droppedCount: Int
    let inputIssueCount: Int
    var correctCount: Int { results.filter { $0.classification == .correct }.count }
    var recall: Double { Double(correctCount) / Double(max(pattern.notes.count, 1)) }
    var extraCount: Int { results.filter { $0.classification == .extra }.count }
    var medianAbsoluteOnsetErrorMilliseconds: Double? {
        let errors = results.filter { $0.classification == .correct }.compactMap { $0.onsetErrorMilliseconds.map(abs) }.sorted()
        guard !errors.isEmpty else { return nil }
        return (errors[(errors.count - 1) / 2] + errors[errors.count / 2]) / 2
    }
    var precision: Double { Double(correctCount) / Double(max(actualNotes.count, 1)) }
    var isClean: Bool {
        isVerified && recall >= 0.95 && precision >= 0.95
            && (medianAbsoluteOnsetErrorMilliseconds.map { $0 <= 25 } ?? false)
            && chords.allSatisfy(\.passes)
            && (!configuration.gradeDuration || (pattern.notes.allSatisfy { $0.durationNanoseconds != nil }
                && Double(results.filter { $0.classification == .correct && $0.durationPassed == true }.count)
                    / Double(max(pattern.notes.count, 1)) >= 0.95))
    }
    var isVerified: Bool {
        pattern.referenceVerified != false && droppedCount == 0 && inputIssueCount == 0 && !actualNotes.contains { $0.isUncertain || $0.isInterrupted }
    }
}
