import Foundation

struct SessionTimeline: Sendable {
    let originHostTime: UInt64
    let converter: any HostTimeConverting

    func sessionTimeNanoseconds(for hostTime: UInt64) -> Int64 {
        if hostTime >= originHostTime {
            return positiveInt64(converter.nanoseconds(forHostTimeDuration: hostTime - originHostTime))
        }

        let nanoseconds = converter.nanoseconds(forHostTimeDuration: originHostTime - hostTime)
        if nanoseconds > UInt64(Int64.max) { return Int64.min }
        return -Int64(nanoseconds)
    }

    func hostTime(addingNanoseconds nanoseconds: UInt64, to hostTime: UInt64) -> UInt64 {
        let ticks = converter.hostTime(forNanosecondDuration: nanoseconds)
        let (result, overflow) = hostTime.addingReportingOverflow(ticks)
        return overflow ? UInt64.max : result
    }

    func makeEvent(
        source: EventSource,
        voice: DrumVoice,
        hostTime: UInt64,
        velocity: Double? = nil,
        confidence: Double = 1,
        metadata: EventMetadata
    ) -> PerformanceEvent {
        PerformanceEvent(
            source: source,
            voice: voice,
            hostTime: hostTime,
            sessionTimeNanoseconds: sessionTimeNanoseconds(for: hostTime),
            velocity: velocity,
            confidence: confidence,
            rawMetadata: metadata
        )
    }

    private func positiveInt64(_ value: UInt64) -> Int64 {
        value > UInt64(Int64.max) ? Int64.max : Int64(value)
    }
}
