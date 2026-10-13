import Foundation

enum InstrumentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case drums
    case electricGuitar
    case electricPiano

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .drums: "Drums"
        case .electricGuitar: "Electric Guitar"
        case .electricPiano: "Electric Piano"
        }
    }

    var symbol: String {
        switch self {
        case .drums: "drum.fill"
        case .electricGuitar: "guitars.fill"
        case .electricPiano: "pianokeys"
        }
    }

    var supportsPractice: Bool { self != .electricGuitar }

    /// Preserve existing drum progress IDs; future instruments have distinct namespaces.
    func progressionKey(for exerciseID: String) -> String {
        self == .drums ? exerciseID : "\(rawValue):\(exerciseID)"
    }
}

struct InstrumentProfile: Identifiable, Codable, Equatable, Sendable {
    var id: InstrumentKind { instrument }
    let instrument: InstrumentKind
    var practiceBPM: Double = 120
    var metronomeBPM: Double = 120
    var measures: Int = 4
    var midiInputID: Int32?
    var audioInputUID: String?
    var audioOutputUID: String?
    var drumPractice: DrumPracticePreferences?
    var pianoPractice: PianoPracticePreferences?
    var recording: InstrumentRecordingPreferences?
    var updatedAt: Date = Date()

    var isValid: Bool {
        (40...240).contains(practiceBPM) && (40...240).contains(metronomeBPM)
            && (1...128).contains(measures)
            && (audioInputUID?.count ?? 0) <= 1_024
            && (audioOutputUID?.count ?? 0) <= 1_024
            && (recording?.isValid ?? true)
            && (drumPractice.map { instrument == .drums && $0.isValid } ?? true)
            && (pianoPractice.map { instrument == .electricPiano && $0.isValid } ?? true)
    }

    static var defaults: [InstrumentProfile] {
        InstrumentKind.allCases.map { InstrumentProfile(instrument: $0, updatedAt: .distantPast) }
    }
}

/// Keeps an in-progress editor separate from the named, saved exercise library.
struct DrumPracticePreferences: Codable, Equatable, Sendable {
    var mode: PracticeExerciseMode
    var exercise: KickExercise
    var customMeasure: CustomMeasureDefinition
    var savedCustomExerciseID: UUID?
    var importedSongID: UUID?
    var sectionStartMeasure: Int
    var sectionEndMeasure: Int
    var sectionRepeats: Int

    var isValid: Bool {
        (1...1_000_000).contains(sectionStartMeasure)
            && (sectionStartMeasure...1_000_000).contains(sectionEndMeasure)
            && (1...32).contains(sectionRepeats)
            && customMeasure.name.count <= 1_024
            && customMeasure.hits.count <= 10_000
            && (customMeasure.sequenceSteps?.count ?? 0) <= 32
            && (customMeasure.sequenceSteps?.allSatisfy { $0.hits.count <= 10_000 && $0.name.count <= 1_024 } ?? true)
    }
}

/// MIDI pitch uses exact octaves; display names use middle C = C4.
struct MIDIPitch: Hashable, Codable, Sendable {
    let noteNumber: UInt8

    init?(_ noteNumber: Int) {
        guard (0...127).contains(noteNumber) else { return nil }
        self.noteNumber = UInt8(noteNumber)
    }

    var pitchClass: Int { Int(noteNumber) % 12 }
    var octave: Int { Int(noteNumber) / 12 - 1 }
    var displayName: String {
        ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][pitchClass] + "\(octave)"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard let pitch = MIDIPitch(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "MIDI pitch must be between 0 and 127.")
        }
        self = pitch
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(noteNumber)
    }
}

enum MusicalTarget: Codable, Hashable, Sendable {
    case drum(DrumVoice)
    case pitched(MIDIPitch)
}

enum NotePart: String, Codable, Sendable {
    case leftHand, rightHand
}

/// Authored fingering, never inferred as observed string usage from mixed audio.
struct GuitarFingering: Codable, Equatable, Sendable {
    let string: Int
    let fret: Int
}

/// Pitched notes live alongside the legacy drum events until pitched scoring lands.
struct PitchedExpectedNote: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let pitch: MIDIPitch
    let onsetNanoseconds: Int64
    let durationNanoseconds: Int64?
    let chordID: UUID?
    let part: NotePart?
    let fingering: GuitarFingering?

    init(id: UUID = UUID(), pitch: MIDIPitch, onsetNanoseconds: Int64,
         durationNanoseconds: Int64? = nil, chordID: UUID? = nil,
         part: NotePart? = nil, fingering: GuitarFingering? = nil) {
        self.id = id
        self.pitch = pitch
        self.onsetNanoseconds = onsetNanoseconds
        self.durationNanoseconds = durationNanoseconds
        self.chordID = chordID
        self.part = part
        self.fingering = fingering
    }

    var target: MusicalTarget { .pitched(pitch) }
    var isValid: Bool {
        (durationNanoseconds.map { $0 >= 0 && !onsetNanoseconds.addingReportingOverflow($0).overflow } ?? true)
            && (fingering.map { (1...6).contains($0.string) && (0...36).contains($0.fret) } ?? true)
    }
}
