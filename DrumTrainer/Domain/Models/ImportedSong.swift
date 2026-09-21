import Foundation

struct MIDITempoChange: Codable, Equatable, Sendable {
    let tick: Int64
    let microsecondsPerQuarterNote: Int

    var bpm: Double { 60_000_000 / Double(microsecondsPerQuarterNote) }
}

struct MIDITimeSignatureChange: Codable, Equatable, Sendable {
    let tick: Int64
    let numerator: Int
    let denominator: Int
}

struct ImportedMIDINoteEvent: Codable, Equatable, Sendable {
    let tick: Int64
    let noteNumber: UInt8
    let velocity: UInt8
    let channel: UInt8
}

struct ImportedMIDITrack: Identifiable, Codable, Equatable, Sendable {
    var id: Int { index }
    let index: Int
    let name: String
    let notes: [ImportedMIDINoteEvent]

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Track \(index + 1)" : trimmed
    }

    var usesPercussionChannel: Bool { notes.contains { $0.channel == 9 } }
}

struct ImportedMIDINoteMapping: Codable, Equatable, Sendable {
    let noteNumber: UInt8
    var voice: DrumVoice
}

struct ImportedSong: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    let sourceFilename: String
    let format: Int
    let ticksPerQuarterNote: Int
    let tempoChanges: [MIDITempoChange]
    let timeSignatureChanges: [MIDITimeSignatureChange]
    let tracks: [ImportedMIDITrack]
    var selectedTrackIndex: Int
    var noteMappings: [ImportedMIDINoteMapping]
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        sourceFilename: String,
        format: Int,
        ticksPerQuarterNote: Int,
        tempoChanges: [MIDITempoChange],
        timeSignatureChanges: [MIDITimeSignatureChange],
        tracks: [ImportedMIDITrack],
        selectedTrackIndex: Int,
        noteMappings: [ImportedMIDINoteMapping],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.sourceFilename = sourceFilename
        self.format = format
        self.ticksPerQuarterNote = ticksPerQuarterNote
        self.tempoChanges = tempoChanges.sorted { $0.tick < $1.tick }
        self.timeSignatureChanges = timeSignatureChanges.sorted { $0.tick < $1.tick }
        self.tracks = tracks
        self.selectedTrackIndex = selectedTrackIndex
        self.noteMappings = noteMappings.sorted { $0.noteNumber < $1.noteNumber }
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? sourceFilename : trimmed
    }

    var selectedTrack: ImportedMIDITrack? {
        tracks.first { $0.index == selectedTrackIndex }
    }

    var originalBPM: Double {
        tempoChanges.first?.bpm ?? 120
    }

    var mappedNoteCount: Int {
        guard let selectedTrack else { return 0 }
        let mapped = Dictionary(uniqueKeysWithValues: noteMappings.map { ($0.noteNumber, $0.voice) })
        return selectedTrack.notes.count { note in
            mapped[note.noteNumber].map(Self.isScorable) ?? false
        }
    }

    func voice(for noteNumber: UInt8) -> DrumVoice {
        noteMappings.first { $0.noteNumber == noteNumber }?.voice ?? .unknown
    }

    mutating func setVoice(_ voice: DrumVoice, for noteNumber: UInt8) {
        if let index = noteMappings.firstIndex(where: { $0.noteNumber == noteNumber }) {
            noteMappings[index].voice = voice
        } else {
            noteMappings.append(ImportedMIDINoteMapping(noteNumber: noteNumber, voice: voice))
        }
        noteMappings.sort { $0.noteNumber < $1.noteNumber }
        updatedAt = Date()
    }

    static func isScorable(_ voice: DrumVoice) -> Bool {
        voice != .unknown && voice != .metronome
    }

    func scorableNoteCount(
        fromMeasure startMeasure: Int,
        throughMeasure endMeasure: Int,
        includeKicks: Bool = true
    ) -> Int {
        guard let selectedTrack else { return 0 }
        let measures = ImportedSongTimeline.measures(for: self)
        guard startMeasure >= 1, endMeasure >= startMeasure, endMeasure <= measures.count else { return 0 }
        let startTick = measures[startMeasure - 1].startTick
        let endTick = measures[endMeasure - 1].endTick
        let mapping = Dictionary(uniqueKeysWithValues: noteMappings.map { ($0.noteNumber, $0.voice) })
        return selectedTrack.notes.count { note in
            guard note.tick >= startTick, note.tick < endTick,
                  let voice = mapping[note.noteNumber], Self.isScorable(voice) else { return false }
            return includeKicks || voice != .kick
        }
    }

    func firstMeasureWithScorableNote(includeKicks: Bool = true) -> Int? {
        guard let selectedTrack else { return nil }
        let mapping = Dictionary(uniqueKeysWithValues: noteMappings.map { ($0.noteNumber, $0.voice) })
        guard let firstTick = selectedTrack.notes.lazy.compactMap({ note -> Int64? in
            guard let voice = mapping[note.noteNumber], Self.isScorable(voice),
                  includeKicks || voice != .kick else { return nil }
            return note.tick
        }).min() else { return nil }
        return ImportedSongTimeline.measures(for: self)
            .first(where: { firstTick >= $0.startTick && firstTick < $0.endTick })?.number
    }
}

struct ImportedMIDINoteSummary: Identifiable, Equatable, Sendable {
    var id: UInt8 { noteNumber }
    let noteNumber: UInt8
    let count: Int
    let channels: Set<UInt8>
}

enum GeneralMIDIDrumMap {
    static func voice(for note: UInt8) -> DrumVoice {
        switch note {
        case 35, 36: .kick
        case 37: .crossStick
        case 38, 40: .snare
        case 41, 43, 45: .lowTom
        case 47, 48: .midTom
        case 50: .highTom
        case 42: .closedHiHat
        case 44: .pedalHiHat
        case 46: .openHiHat
        case 49: .crash1
        case 51, 59: .ride
        case 52: .china
        case 53: .rideBell
        case 55, 57: .crash2
        case 56: .other
        case 54: .other
        default: .unknown
        }
    }
}

struct ImportedSongMeasure: Equatable, Sendable {
    let number: Int
    let startTick: Int64
    let endTick: Int64
    let numerator: Int
    let denominator: Int
}

enum ImportedSongTimeline {
    static func measures(for song: ImportedSong) -> [ImportedSongMeasure] {
        let lastNoteTick = song.tracks.flatMap(\.notes).map(\.tick).max() ?? 0
        let lastSignatureTick = song.timeSignatureChanges.map(\.tick).max() ?? 0
        let finalEvidenceTick = max(lastNoteTick, lastSignatureTick)
        var signatures = normalizedSignatures(song.timeSignatureChanges)
        if signatures.isEmpty {
            signatures = [MIDITimeSignatureChange(tick: 0, numerator: 4, denominator: 4)]
        } else if signatures[0].tick > 0 {
            signatures.insert(MIDITimeSignatureChange(tick: 0, numerator: 4, denominator: 4), at: 0)
        }

        var result: [ImportedSongMeasure] = []
        var tick: Int64 = 0
        var signatureIndex = 0
        let ppq = Int64(song.ticksPerQuarterNote)
        let hardLimit = 10_000

        while (tick <= finalEvidenceTick || result.isEmpty), result.count < hardLimit {
            while signatureIndex + 1 < signatures.count,
                  signatures[signatureIndex + 1].tick <= tick {
                signatureIndex += 1
            }
            let signature = signatures[signatureIndex]
            let ticksPerBeat = max(ppq * 4 / Int64(signature.denominator), 1)
            var endTick = tick + ticksPerBeat * Int64(signature.numerator)
            if signatureIndex + 1 < signatures.count {
                let nextChange = signatures[signatureIndex + 1].tick
                if nextChange > tick && nextChange < endTick { endTick = nextChange }
            }
            result.append(ImportedSongMeasure(
                number: result.count + 1,
                startTick: tick,
                endTick: endTick,
                numerator: signature.numerator,
                denominator: signature.denominator
            ))
            tick = endTick
        }
        return result
    }

    static func nanoseconds(
        from startTick: Int64,
        to endTick: Int64,
        song: ImportedSong
    ) -> Int64 {
        guard endTick > startTick else { return 0 }
        var tempos = song.tempoChanges
            .filter { $0.microsecondsPerQuarterNote > 0 }
            .sorted { $0.tick < $1.tick }
        if tempos.isEmpty || tempos[0].tick > 0 {
            tempos.insert(MIDITempoChange(tick: 0, microsecondsPerQuarterNote: 500_000), at: 0)
        }
        var cursor = startTick
        var totalMicroseconds = 0.0
        var tempoIndex = tempos.lastIndex { $0.tick <= startTick } ?? 0
        let ppq = Double(song.ticksPerQuarterNote)

        while cursor < endTick {
            let nextTempoTick = tempoIndex + 1 < tempos.count ? tempos[tempoIndex + 1].tick : endTick
            let segmentEnd = min(endTick, max(cursor, nextTempoTick))
            let ticks = segmentEnd - cursor
            totalMicroseconds += Double(ticks) * Double(tempos[tempoIndex].microsecondsPerQuarterNote) / ppq
            cursor = segmentEnd
            if tempoIndex + 1 < tempos.count, cursor >= tempos[tempoIndex + 1].tick {
                tempoIndex += 1
            } else if cursor < endTick, segmentEnd == cursor {
                break
            }
        }
        return Int64(min(totalMicroseconds * 1_000, Double(Int64.max)).rounded())
    }

    static func bpm(at tick: Int64, song: ImportedSong) -> Double {
        song.tempoChanges.last { $0.tick <= tick }?.bpm ?? 120
    }

    private static func normalizedSignatures(
        _ signatures: [MIDITimeSignatureChange]
    ) -> [MIDITimeSignatureChange] {
        signatures
            .filter { $0.tick >= 0 && $0.numerator > 0 && $0.denominator > 0 }
            .sorted { $0.tick < $1.tick }
            .reduce(into: []) { result, signature in
                if result.last?.tick == signature.tick { result[result.count - 1] = signature }
                else { result.append(signature) }
            }
    }
}
