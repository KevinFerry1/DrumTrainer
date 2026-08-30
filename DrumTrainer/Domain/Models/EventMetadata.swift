import Foundation

enum EventMetadata: Codable, Equatable, Sendable {
    case midi(channel: UInt8, note: UInt8, velocity: UInt8, endpointName: String?)
    case microphone(amplitude: Double, threshold: Double, frameOffset: Int)
    case metronome(beat: Int, subdivision: Int)
    case simulated(label: String)

    var diagnosticSummary: String {
        switch self {
        case let .midi(channel, note, velocity, endpointName):
            "note \(note), velocity \(velocity), ch \(channel)" + (endpointName.map { ", \($0)" } ?? "")
        case let .microphone(amplitude, threshold, frameOffset):
            "amplitude \(amplitude.formatted(.number.precision(.fractionLength(2)))), threshold \(threshold.formatted(.number.precision(.fractionLength(2)))), frame \(frameOffset)"
        case let .metronome(beat, subdivision):
            subdivision == 0 ? "beat \(beat)" : "beat \(beat), subdivision \(subdivision)"
        case let .simulated(label):
            label
        }
    }
}
