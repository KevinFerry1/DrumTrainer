import Foundation
enum InstrumentKind: String, Codable, Sendable { case drums }
enum MusicalTarget { case drum(DrumVoice) }
struct MeasureFixture: Codable { let number: Int; let startTick: Int64; let endTick: Int64; let numerator: Int; let denominator: Int }
struct MIDIFixture: Codable { let name: String; let bytes: [UInt8]; let song: ImportedSong?; let measures: [MeasureFixture]; let pattern: PracticePattern?; let error: String? }
struct MIDIInput: Codable { let name: String; let bytes: [UInt8] }
@main struct GenerateMIDIFixtures {
    static func main() throws {
        let cases = try JSONDecoder().decode([MIDIInput].self, from: Data(contentsOf: URL(fileURLWithPath: "Windows/validation/midi-inputs.json")))
        let fixtures = cases.map { input -> MIDIFixture in
            let name = input.name, bytes = input.bytes
            do {
                let song = try StandardMIDIFileParser().parse(data: Data(bytes), filename: "\(name).mid")
                let measures = ImportedSongTimeline.measures(for: song)
                let pattern = try ImportedSongPatternGenerator().generate(song: song, configuration: ImportedSongSectionConfiguration(startMeasure: 1, endMeasure: min(2, measures.count), repeats: 2, targetBPM: 113))
                return MIDIFixture(name: name, bytes: bytes, song: song, measures: measures.map { MeasureFixture(number: $0.number, startTick: $0.startTick, endTick: $0.endTick, numerator: $0.numerator, denominator: $0.denominator) }, pattern: pattern, error: nil)
            } catch { return MIDIFixture(name: name, bytes: bytes, song: nil, measures: [], pattern: nil, error: error.localizedDescription) }
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(fixtures).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("Generated \(fixtures.count) native MIDI import and section fixtures.")
    }
}
