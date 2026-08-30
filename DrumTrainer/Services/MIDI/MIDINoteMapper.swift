import Foundation

protocol MIDIMappingPersisting: Sendable {
    func loadMapping(for deviceID: Int32) -> [UInt8: DrumVoice]
    func saveMapping(_ mapping: [UInt8: DrumVoice], for deviceID: Int32)
}

final class UserDefaultsMIDIMappingStore: MIDIMappingPersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadMapping(for deviceID: Int32) -> [UInt8: DrumVoice] {
        lock.withLock {
            guard let data = defaults.data(forKey: key(for: deviceID)) else { return [:] }
            return (try? JSONDecoder().decode([UInt8: DrumVoice].self, from: data)) ?? [:]
        }
    }

    func saveMapping(_ mapping: [UInt8: DrumVoice], for deviceID: Int32) {
        lock.withLock {
            let key = key(for: deviceID)
            guard !mapping.isEmpty else {
                defaults.removeObject(forKey: key)
                return
            }
            if let data = try? JSONEncoder().encode(mapping) {
                defaults.set(data, forKey: key)
            }
        }
    }

    private func key(for deviceID: Int32) -> String {
        "DrumTrainer.midiMapping.\(deviceID)"
    }
}

struct MIDINoteMapper: Sendable {
    private let mapping: [UInt8: DrumVoice]

    init(mapping: [UInt8: DrumVoice] = Self.generalMIDIMap) {
        self.mapping = mapping
    }

    init(overrides: [UInt8: DrumVoice]) {
        self.mapping = Self.generalMIDIMap.merging(overrides) { _, override in override }
    }

    func voice(for note: UInt8) -> DrumVoice {
        mapping[note] ?? .unknown
    }

    static let generalMIDIMap: [UInt8: DrumVoice] = [
        35: .kick, 36: .kick,
        37: .crossStick, 38: .snare, 40: .snare,
        41: .lowTom, 43: .lowTom, 45: .midTom, 47: .midTom, 48: .highTom, 50: .highTom,
        42: .closedHiHat, 44: .pedalHiHat, 46: .openHiHat,
        49: .crash1, 52: .china, 55: .splash, 57: .crash2,
        51: .ride, 53: .rideBell, 59: .ride
    ]
}
