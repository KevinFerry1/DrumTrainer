import XCTest
@testable import DrumTrainer

final class MIDI1UMPParserTests: XCTestCase {
    func testParsesMIDI1NoteOnWord() {
        let word: UInt32 = 0x2099_2668 // MIDI 1, channel 10, note 38, velocity 104

        XCTAssertEqual(
            MIDI1UMPParser.noteOn(from: word, hostTime: 1234),
            MIDINoteOn(channel: 10, note: 38, velocity: 104, hostTime: 1234)
        )
    }

    func testVelocityZeroAndNoteOffAreIgnored() {
        XCTAssertNil(MIDI1UMPParser.noteOn(from: 0x2099_2600, hostTime: 1))
        XCTAssertNil(MIDI1UMPParser.noteOn(from: 0x2089_2668, hostTime: 1))
    }

    func testNonMIDI1UMPIsIgnored() {
        XCTAssertNil(MIDI1UMPParser.noteOn(from: 0x4099_2668, hostTime: 1))
    }
}
