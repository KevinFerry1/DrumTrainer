import Foundation

enum EventSource: String, Codable, Hashable, Sendable {
    case midi
    case microphone
    case metronome
    case simulation

    var displayName: String { rawValue.uppercased() }
}
