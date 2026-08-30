import XCTest
@testable import DrumTrainer

final class MIDINoteMapperTests: XCTestCase {
    func testGeneralMIDINotesMapToCanonicalVoices() {
        let mapper = MIDINoteMapper()

        XCTAssertEqual(mapper.voice(for: 36), .kick)
        XCTAssertEqual(mapper.voice(for: 38), .snare)
        XCTAssertEqual(mapper.voice(for: 42), .closedHiHat)
        XCTAssertEqual(mapper.voice(for: 51), .ride)
    }

    func testUnmappedNoteRemainsVisibleAsUnknown() {
        XCTAssertEqual(MIDINoteMapper().voice(for: 1), .unknown)
    }

    func testDeviceOverrideWinsOverGeneralMIDIDefault() {
        let mapper = MIDINoteMapper(overrides: [38: .highTom, 72: .china])

        XCTAssertEqual(mapper.voice(for: 38), .highTom)
        XCTAssertEqual(mapper.voice(for: 72), .china)
        XCTAssertEqual(mapper.voice(for: 42), .closedHiHat)
    }

    func testMappingsPersistSeparatelyByDevice() throws {
        let suiteName = "MIDINoteMapperTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsMIDIMappingStore(defaults: defaults)

        store.saveMapping([38: .snare], for: 101)
        store.saveMapping([38: .crossStick], for: 202)

        XCTAssertEqual(store.loadMapping(for: 101), [38: .snare])
        XCTAssertEqual(store.loadMapping(for: 202), [38: .crossStick])
        XCTAssertEqual(store.loadMapping(for: 303), [:])
    }
}
