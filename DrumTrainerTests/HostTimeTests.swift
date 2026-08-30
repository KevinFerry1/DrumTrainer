import XCTest
@testable import DrumTrainer

final class HostTimeTests: XCTestCase {
    func testEventTimestampFormattingCanExposeRawSourceHostTime() {
        let event = PerformanceEvent(
            source: .midi,
            voice: .snare,
            hostTime: 12_345_678,
            sessionTimeNanoseconds: 1_250_000_000,
            rawMetadata: .simulated(label: "test")
        )

        XCTAssertEqual(event.formattedTimestamp(.rawHost), "12345678")
        XCTAssertEqual(event.formattedTimestamp(.session), "1.250 s")
    }

    func testSessionTimeIsRelativeToOriginInNanoseconds() {
        let timeline = SessionTimeline(
            originHostTime: 1_000,
            converter: LinearHostTimeConverter(nanosecondsPerTick: 10)
        )

        XCTAssertEqual(timeline.sessionTimeNanoseconds(for: 1_250), 2_500)
        XCTAssertEqual(timeline.sessionTimeNanoseconds(for: 900), -1_000)
    }

    func testFrameOffsetCanBeConvertedBackToHostTime() {
        let timeline = SessionTimeline(
            originHostTime: 10_000,
            converter: LinearHostTimeConverter(nanosecondsPerTick: 100)
        )

        XCTAssertEqual(timeline.hostTime(addingNanoseconds: 25_000, to: 10_000), 10_250)
    }
}
