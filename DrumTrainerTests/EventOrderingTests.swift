import XCTest
@testable import DrumTrainer

final class EventOrderingTests: XCTestCase {
    func testMixedSourcesAreOrderedAndBufferIsBounded() {
        var buffer = BoundedEventBuffer(capacity: 3)
        buffer.append(event(at: 30, source: .microphone))
        buffer.append(event(at: 10, source: .midi))
        buffer.append(event(at: 20, source: .metronome))

        XCTAssertEqual(buffer.events.map(\.sessionTimeNanoseconds), [10, 20, 30])

        buffer.append(event(at: 40, source: .midi))

        XCTAssertEqual(buffer.events.map(\.sessionTimeNanoseconds), [20, 30, 40])
        XCTAssertEqual(buffer.droppedCount, 1)
    }

    private func event(at time: Int64, source: EventSource) -> PerformanceEvent {
        PerformanceEvent(
            source: source,
            voice: .unknown,
            hostTime: UInt64(time),
            sessionTimeNanoseconds: time,
            rawMetadata: .simulated(label: "test")
        )
    }
}
