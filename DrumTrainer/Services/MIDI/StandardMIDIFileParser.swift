import Foundation

enum StandardMIDIFileError: LocalizedError, Equatable {
    case invalidHeader
    case unsupportedFormat(Int)
    case unsupportedSMPTETimeDivision
    case truncatedFile
    case malformedTrack(Int)
    case noPlayableTracks

    var errorDescription: String? {
        switch self {
        case .invalidHeader: "This is not a valid Standard MIDI file."
        case let .unsupportedFormat(format): "MIDI format \(format) is not supported. Use format 0 or 1."
        case .unsupportedSMPTETimeDivision: "SMPTE-timed MIDI files are not supported yet; export with ticks per quarter note."
        case .truncatedFile: "The MIDI file ends unexpectedly."
        case let .malformedTrack(index): "MIDI track \(index + 1) contains malformed event data."
        case .noPlayableTracks: "The MIDI file contains no note events to import."
        }
    }
}

struct StandardMIDIFileParser: Sendable {
    func parse(data: Data, filename: String) throws -> ImportedSong {
        var reader = MIDIByteReader(data: data)
        guard try reader.readASCII(count: 4) == "MThd" else { throw StandardMIDIFileError.invalidHeader }
        let headerLength = Int(try reader.readUInt32())
        guard headerLength >= 6 else { throw StandardMIDIFileError.invalidHeader }
        let format = Int(try reader.readUInt16())
        guard format == 0 || format == 1 else { throw StandardMIDIFileError.unsupportedFormat(format) }
        let trackCount = Int(try reader.readUInt16())
        let division = try reader.readUInt16()
        guard division & 0x8000 == 0 else { throw StandardMIDIFileError.unsupportedSMPTETimeDivision }
        let ppq = Int(division)
        guard ppq > 0 else { throw StandardMIDIFileError.invalidHeader }
        try reader.skip(headerLength - 6)

        var tracks: [ImportedMIDITrack] = []
        var tempos: [MIDITempoChange] = []
        var signatures: [MIDITimeSignatureChange] = []

        for trackIndex in 0..<trackCount {
            guard try reader.readASCII(count: 4) == "MTrk" else {
                throw StandardMIDIFileError.malformedTrack(trackIndex)
            }
            let length = Int(try reader.readUInt32())
            let trackData = try reader.readData(count: length)
            let parsed = try parseTrack(trackData, index: trackIndex)
            tracks.append(ImportedMIDITrack(
                index: trackIndex,
                name: parsed.name,
                notes: parsed.notes.sorted { lhs, rhs in
                    lhs.tick == rhs.tick ? lhs.noteNumber < rhs.noteNumber : lhs.tick < rhs.tick
                }
            ))
            tempos.append(contentsOf: parsed.tempos)
            signatures.append(contentsOf: parsed.signatures)
        }

        let playableTracks = tracks.filter { !$0.notes.isEmpty }
        guard !playableTracks.isEmpty else { throw StandardMIDIFileError.noPlayableTracks }
        let selected = playableTracks.first(where: \.usesPercussionChannel) ?? playableTracks.max {
            $0.notes.count < $1.notes.count
        }!
        let summaries = Dictionary(grouping: selected.notes, by: \.noteNumber)
        let mappings = summaries.keys.sorted().map { note in
            ImportedMIDINoteMapping(noteNumber: note, voice: GeneralMIDIDrumMap.voice(for: note))
        }
        let baseName = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent

        return ImportedSong(
            name: baseName,
            sourceFilename: filename,
            format: format,
            ticksPerQuarterNote: ppq,
            tempoChanges: normalizedTempos(tempos),
            timeSignatureChanges: normalizedSignatures(signatures),
            tracks: tracks,
            selectedTrackIndex: selected.index,
            noteMappings: mappings
        )
    }

    private func parseTrack(_ data: Data, index: Int) throws -> ParsedTrack {
        var reader = MIDIByteReader(data: data)
        var absoluteTick: Int64 = 0
        var runningStatus: UInt8?
        var name = ""
        var notes: [ImportedMIDINoteEvent] = []
        var tempos: [MIDITempoChange] = []
        var signatures: [MIDITimeSignatureChange] = []

        do {
            while !reader.isAtEnd {
                absoluteTick += Int64(try reader.readVariableLengthQuantity())
                let first = try reader.peekUInt8()
                let status: UInt8
                if first & 0x80 != 0 {
                    status = try reader.readUInt8()
                    if status < 0xF0 { runningStatus = status }
                } else if let runningStatus {
                    status = runningStatus
                } else {
                    throw StandardMIDIFileError.malformedTrack(index)
                }

                if status == 0xFF {
                    runningStatus = nil
                    let type = try reader.readUInt8()
                    let length = Int(try reader.readVariableLengthQuantity())
                    let payload = try reader.readData(count: length)
                    switch type {
                    case 0x03:
                        name = String(data: payload, encoding: .utf8)
                            ?? String(data: payload, encoding: .ascii)
                            ?? name
                    case 0x51 where payload.count == 3:
                        let value = payload.reduce(0) { ($0 << 8) | Int($1) }
                        if value > 0 {
                            tempos.append(MIDITempoChange(tick: absoluteTick, microsecondsPerQuarterNote: value))
                        }
                    case 0x58 where payload.count >= 2:
                        let power = min(Int(payload[payload.startIndex + 1]), 30)
                        signatures.append(MIDITimeSignatureChange(
                            tick: absoluteTick,
                            numerator: max(Int(payload[payload.startIndex]), 1),
                            denominator: 1 << power
                        ))
                    case 0x2F:
                        return ParsedTrack(name: name, notes: notes, tempos: tempos, signatures: signatures)
                    default:
                        break
                    }
                } else if status == 0xF0 || status == 0xF7 {
                    runningStatus = nil
                    try reader.skip(Int(try reader.readVariableLengthQuantity()))
                } else {
                    let command = status & 0xF0
                    let channel = status & 0x0F
                    switch command {
                    case 0x80, 0x90, 0xA0, 0xB0, 0xE0:
                        let data1 = try reader.readUInt8()
                        let data2 = try reader.readUInt8()
                        if command == 0x90, data2 > 0 {
                            notes.append(ImportedMIDINoteEvent(
                                tick: absoluteTick,
                                noteNumber: data1,
                                velocity: data2,
                                channel: channel
                            ))
                        }
                    case 0xC0, 0xD0:
                        _ = try reader.readUInt8()
                    default:
                        throw StandardMIDIFileError.malformedTrack(index)
                    }
                }
            }
        } catch let error as StandardMIDIFileError {
            throw error
        } catch {
            throw StandardMIDIFileError.malformedTrack(index)
        }
        return ParsedTrack(name: name, notes: notes, tempos: tempos, signatures: signatures)
    }

    private func normalizedTempos(_ values: [MIDITempoChange]) -> [MIDITempoChange] {
        var result = values.sorted { $0.tick < $1.tick }.reduce(into: [MIDITempoChange]()) { result, value in
            if result.last?.tick == value.tick { result[result.count - 1] = value }
            else { result.append(value) }
        }
        if result.isEmpty || result[0].tick > 0 {
            result.insert(MIDITempoChange(tick: 0, microsecondsPerQuarterNote: 500_000), at: 0)
        }
        return result
    }

    private func normalizedSignatures(_ values: [MIDITimeSignatureChange]) -> [MIDITimeSignatureChange] {
        var result = values.sorted { $0.tick < $1.tick }.reduce(into: [MIDITimeSignatureChange]()) { result, value in
            if result.last?.tick == value.tick { result[result.count - 1] = value }
            else { result.append(value) }
        }
        if result.isEmpty || result[0].tick > 0 {
            result.insert(MIDITimeSignatureChange(tick: 0, numerator: 4, denominator: 4), at: 0)
        }
        return result
    }

    private struct ParsedTrack {
        let name: String
        let notes: [ImportedMIDINoteEvent]
        let tempos: [MIDITempoChange]
        let signatures: [MIDITimeSignatureChange]
    }
}

private struct MIDIByteReader {
    let data: Data
    var offset = 0

    var isAtEnd: Bool { offset >= data.count }

    mutating func readUInt8() throws -> UInt8 {
        guard offset < data.count else { throw StandardMIDIFileError.truncatedFile }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    func peekUInt8() throws -> UInt8 {
        guard offset < data.count else { throw StandardMIDIFileError.truncatedFile }
        return data[data.startIndex + offset]
    }

    mutating func readUInt16() throws -> UInt16 {
        (UInt16(try readUInt8()) << 8) | UInt16(try readUInt8())
    }

    mutating func readUInt32() throws -> UInt32 {
        (UInt32(try readUInt8()) << 24)
            | (UInt32(try readUInt8()) << 16)
            | (UInt32(try readUInt8()) << 8)
            | UInt32(try readUInt8())
    }

    mutating func readVariableLengthQuantity() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            let byte = try readUInt8()
            value = (value << 7) | UInt32(byte & 0x7F)
            if byte & 0x80 == 0 { return value }
        }
        throw StandardMIDIFileError.truncatedFile
    }

    mutating func readASCII(count: Int) throws -> String {
        let bytes = try readData(count: count)
        guard let value = String(data: bytes, encoding: .ascii) else {
            throw StandardMIDIFileError.invalidHeader
        }
        return value
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset <= data.count - count else { throw StandardMIDIFileError.truncatedFile }
        let range = (data.startIndex + offset)..<(data.startIndex + offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset <= data.count - count else { throw StandardMIDIFileError.truncatedFile }
        offset += count
    }
}
