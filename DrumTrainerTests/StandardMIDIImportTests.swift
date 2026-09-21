import XCTest
@testable import DrumTrainer

final class StandardMIDIImportTests: XCTestCase {
    func testParsesFormatOneTempoMeterTrackNameRunningStatusAndGMDrums() throws {
        let song = try StandardMIDIFileParser().parse(data: makeMIDI(), filename: "Niche Song.mid")

        XCTAssertEqual(song.format, 1)
        XCTAssertEqual(song.ticksPerQuarterNote, 480)
        XCTAssertEqual(song.tracks.count, 2)
        XCTAssertEqual(song.selectedTrackIndex, 1)
        XCTAssertEqual(song.selectedTrack?.displayName, "Drums")
        XCTAssertEqual(song.selectedTrack?.notes.map(\.tick), [0, 240, 480])
        XCTAssertEqual(song.selectedTrack?.notes.map(\.noteNumber), [36, 38, 42])
        XCTAssertTrue(song.selectedTrack?.usesPercussionChannel == true)
        XCTAssertEqual(song.tempoChanges.map(\.microsecondsPerQuarterNote), [500_000, 600_000])
        XCTAssertEqual(song.timeSignatureChanges.first?.numerator, 4)
        XCTAssertEqual(song.timeSignatureChanges.first?.denominator, 4)
        XCTAssertEqual(song.voice(for: 36), .kick)
        XCTAssertEqual(song.voice(for: 38), .snare)
        XCTAssertEqual(song.voice(for: 42), .closedHiHat)
    }

    func testGeneratesRepeatedSectionUsingTempoMapAndEditableMapping() throws {
        var song = try StandardMIDIFileParser().parse(data: makeMIDI(), filename: "Niche Song.mid")
        song.setVoice(.ride, for: 42)

        let pattern = try ImportedSongPatternGenerator().generate(
            song: song,
            configuration: ImportedSongSectionConfiguration(
                startMeasure: 1,
                endMeasure: 1,
                repeats: 2,
                targetBPM: 60
            ),
            startSessionTimeNanoseconds: 10_000
        )

        XCTAssertEqual(pattern.name, "Niche Song")
        XCTAssertEqual(pattern.measures, 2)
        XCTAssertEqual(pattern.expectedEvents.count, 6)
        XCTAssertEqual(pattern.expectedEvents.map(\.voice), [.kick, .snare, .ride, .kick, .snare, .ride])
        XCTAssertEqual(pattern.expectedEvents[0].sessionTimeNanoseconds, 10_000)
        XCTAssertEqual(pattern.expectedEvents[1].sessionTimeNanoseconds, 500_010_000)
        XCTAssertEqual(pattern.expectedEvents[2].sessionTimeNanoseconds, 1_000_010_000)
        XCTAssertEqual(pattern.durationNanoseconds, 9_200_000_000)
        XCTAssertEqual(pattern.measureStartOffsetsNanoseconds, [0, 4_600_000_000, 9_200_000_000])
        XCTAssertEqual(pattern.measureSignatures, [
            PracticeMeasureSignature(numerator: 4, denominator: 4),
            PracticeMeasureSignature(numerator: 4, denominator: 4)
        ])
        XCTAssertEqual(pattern.referenceBeats?.map(\.offsetNanoseconds), [
            0, 1_000_000_000, 2_200_000_000, 3_400_000_000,
            4_600_000_000, 5_600_000_000, 6_800_000_000, 8_000_000_000
        ])
        XCTAssertEqual(pattern.referenceBeats?.map(\.beat), [1, 2, 3, 4, 1, 2, 3, 4])
        XCTAssertEqual(pattern.referenceBeats?.map(\.isAccent), [true, false, false, false, true, false, false, false])
    }

    func testFindsFirstScorableMeasureAndCountsOnlyTheSelectedSection() {
        let song = ImportedSong(
            name: "Long intro",
            sourceFilename: "Long intro.mid",
            format: 1,
            ticksPerQuarterNote: 480,
            tempoChanges: [MIDITempoChange(tick: 0, microsecondsPerQuarterNote: 500_000)],
            timeSignatureChanges: [MIDITimeSignatureChange(tick: 0, numerator: 4, denominator: 4)],
            tracks: [ImportedMIDITrack(index: 0, name: "Drums", notes: [
                ImportedMIDINoteEvent(tick: 1_920, noteNumber: 36, velocity: 100, channel: 9),
                ImportedMIDINoteEvent(tick: 7_680, noteNumber: 38, velocity: 100, channel: 9),
                ImportedMIDINoteEvent(tick: 7_920, noteNumber: 42, velocity: 90, channel: 9)
            ])],
            selectedTrackIndex: 0,
            noteMappings: [
                ImportedMIDINoteMapping(noteNumber: 36, voice: .kick),
                ImportedMIDINoteMapping(noteNumber: 38, voice: .snare),
                ImportedMIDINoteMapping(noteNumber: 42, voice: .closedHiHat)
            ]
        )

        XCTAssertEqual(song.firstMeasureWithScorableNote(), 2)
        XCTAssertEqual(song.firstMeasureWithScorableNote(includeKicks: false), 5)
        XCTAssertEqual(song.scorableNoteCount(fromMeasure: 1, throughMeasure: 1), 0)
        XCTAssertEqual(song.scorableNoteCount(fromMeasure: 2, throughMeasure: 2), 1)
        XCTAssertEqual(song.scorableNoteCount(fromMeasure: 2, throughMeasure: 2, includeKicks: false), 0)
        XCTAssertEqual(song.scorableNoteCount(fromMeasure: 5, throughMeasure: 5, includeKicks: false), 2)
        XCTAssertEqual(song.scorableNoteCount(fromMeasure: 0, throughMeasure: 5), 0)
    }

    func testImportedSongPersistsInCurrentSchemaArchive() throws {
        let song = try StandardMIDIFileParser().parse(data: makeMIDI(), filename: "Niche Song.mid")
        let data = try PracticeDataArchive(importedSongs: [song]).encodedJSON()
        let decoded = try PracticeDataArchive.decodeAndValidate(data)

        XCTAssertEqual(decoded.schemaVersion, PracticeDataArchive.currentSchemaVersion)
        XCTAssertEqual(decoded.importedSongs, [song])
    }

    func testRejectsSMPTETimeDivision() {
        let bytes: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6,
            0, 0, 0, 1, 0xE7, 0x28,
            0x4D, 0x54, 0x72, 0x6B, 0, 0, 0, 4,
            0, 0xFF, 0x2F, 0
        ]
        XCTAssertThrowsError(try StandardMIDIFileParser().parse(data: Data(bytes), filename: "bad.mid")) { error in
            XCTAssertEqual(error as? StandardMIDIFileError, .unsupportedSMPTETimeDivision)
        }
    }

    private func makeMIDI() -> Data {
        var bytes: [UInt8] = [
            0x4D, 0x54, 0x68, 0x64, 0, 0, 0, 6,
            0, 1, 0, 2, 0x01, 0xE0
        ]
        appendTrack([
            0, 0xFF, 0x51, 3, 0x07, 0xA1, 0x20,
            0, 0xFF, 0x58, 4, 4, 2, 24, 8,
            0x83, 0x60, 0xFF, 0x51, 3, 0x09, 0x27, 0xC0,
            0, 0xFF, 0x2F, 0
        ], to: &bytes)
        appendTrack([
            0, 0xFF, 0x03, 5, 0x44, 0x72, 0x75, 0x6D, 0x73,
            0, 0x99, 36, 100,
            0x81, 0x70, 38, 110,
            0x81, 0x70, 42, 90,
            0, 0xFF, 0x2F, 0
        ], to: &bytes)
        return Data(bytes)
    }

    private func appendTrack(_ track: [UInt8], to bytes: inout [UInt8]) {
        bytes.append(contentsOf: [0x4D, 0x54, 0x72, 0x6B])
        let length = UInt32(track.count)
        bytes.append(UInt8((length >> 24) & 0xFF))
        bytes.append(UInt8((length >> 16) & 0xFF))
        bytes.append(UInt8((length >> 8) & 0xFF))
        bytes.append(UInt8(length & 0xFF))
        bytes.append(contentsOf: track)
    }
}
