import Foundation

struct EventStreamSnapshot: Sendable {
    let events: [PerformanceEvent]
    let droppedCount: Int
}

struct BoundedEventBuffer: Sendable {
    let capacity: Int
    private(set) var events: [PerformanceEvent] = []
    private(set) var droppedCount = 0

    init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    mutating func append(_ event: PerformanceEvent) {
        let insertionIndex = events.firstIndex {
            $0.sessionTimeNanoseconds > event.sessionTimeNanoseconds
        } ?? events.endIndex
        events.insert(event, at: insertionIndex)

        if events.count > capacity {
            events.removeFirst(events.count - capacity)
            droppedCount += 1
        }
    }

    mutating func clear() {
        events.removeAll(keepingCapacity: true)
        droppedCount = 0
    }
}

actor UnifiedEventStream {
    private var buffer: BoundedEventBuffer

    init(capacity: Int) {
        buffer = BoundedEventBuffer(capacity: capacity)
    }

    func append(_ event: PerformanceEvent) -> EventStreamSnapshot {
        buffer.append(event)
        return EventStreamSnapshot(events: buffer.events, droppedCount: buffer.droppedCount)
    }

    func clear() -> EventStreamSnapshot {
        buffer.clear()
        return EventStreamSnapshot(events: buffer.events, droppedCount: buffer.droppedCount)
    }
}
