import Foundation

enum EventTimestampDisplayMode: String, CaseIterable, Identifiable, Sendable {
    case session
    case rawHost

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .session: "Session time"
        case .rawHost: "Raw host ticks"
        }
    }

    var columnTitle: String {
        switch self {
        case .session: "Session time"
        case .rawHost: "Host time"
        }
    }
}

struct PerformanceEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID?
    let source: EventSource
    let voice: DrumVoice
    let hostTime: UInt64
    let sessionTimeNanoseconds: Int64
    let velocity: Double?
    let confidence: Double
    let rawMetadata: EventMetadata
    let audioFeatures: AudioTransientFeatures?

    init(
        id: UUID = UUID(),
        sessionID: UUID? = nil,
        source: EventSource,
        voice: DrumVoice,
        hostTime: UInt64,
        sessionTimeNanoseconds: Int64,
        velocity: Double? = nil,
        confidence: Double = 1,
        rawMetadata: EventMetadata,
        audioFeatures: AudioTransientFeatures? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.source = source
        self.voice = voice
        self.hostTime = hostTime
        self.sessionTimeNanoseconds = sessionTimeNanoseconds
        self.velocity = velocity
        self.confidence = min(max(confidence, 0), 1)
        self.rawMetadata = rawMetadata
        self.audioFeatures = audioFeatures
    }

    var formattedSessionTime: String {
        let seconds = Double(sessionTimeNanoseconds) / 1_000_000_000
        return seconds.formatted(.number.precision(.fractionLength(3))) + " s"
    }

    func formattedTimestamp(_ mode: EventTimestampDisplayMode) -> String {
        switch mode {
        case .session: formattedSessionTime
        case .rawHost: hostTime.formatted(.number.grouping(.never))
        }
    }
}
