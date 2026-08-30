import Foundation

enum DrumVoice: String, CaseIterable, Codable, Hashable, Sendable {
    case kick
    case snare
    case crossStick
    case highTom
    case midTom
    case lowTom
    case closedHiHat
    case openHiHat
    case pedalHiHat
    case ride
    case rideBell
    case crash1
    case crash2
    case china
    case splash
    case metronome
    case other
    case unknown

    var displayName: String {
        switch self {
        case .kick: "Kick"
        case .snare: "Snare"
        case .crossStick: "Cross-stick / rim"
        case .highTom: "High tom"
        case .midTom: "Mid tom"
        case .lowTom: "Low tom"
        case .closedHiHat: "Closed hi-hat"
        case .openHiHat: "Open hi-hat"
        case .pedalHiHat: "Pedal hi-hat"
        case .ride: "Ride"
        case .rideBell: "Ride bell"
        case .crash1: "Crash 1"
        case .crash2: "Crash 2"
        case .china: "China"
        case .splash: "Splash"
        case .metronome: "Reference beat"
        case .other: "Other"
        case .unknown: "Unknown"
        }
    }
}
