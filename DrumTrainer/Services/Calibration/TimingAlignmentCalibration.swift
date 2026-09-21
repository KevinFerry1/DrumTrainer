import Foundation

enum TimingAlignmentSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case midi
    case microphone

    var id: String { rawValue }
    var eventSource: EventSource { self == .midi ? .midi : .microphone }
    var displayName: String { self == .midi ? "E-kit MIDI" : "Kick microphone" }
}

struct TimingAlignmentProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let source: TimingAlignmentSource
    let inputID: String
    let inputName: String
    let outputUID: String
    let outputName: String
    let voice: DrumVoice
    let compensationMilliseconds: Double
    let medianAbsoluteDeviationMilliseconds: Double
    let sampleCount: Int
    let createdAt: Date

    /// MIDI alignment is intentionally device-wide. `.unknown` is persisted as the
    /// shared MIDI scope so older per-voice profiles remain decodable but are ignored.
    var scopeDisplayName: String {
        source == .midi ? "All e-kit MIDI drums" : voice.displayName
    }

    var key: String {
        Self.key(source: source, inputID: inputID, outputUID: outputUID, voice: voice)
    }

    static func key(
        source: TimingAlignmentSource,
        inputID: String,
        outputUID: String,
        voice: DrumVoice
    ) -> String {
        "\(source.rawValue)|\(inputID)|\(outputUID)|\(voice.rawValue)"
    }
}

protocol TimingAlignmentPersisting: Sendable {
    func loadProfiles() -> [TimingAlignmentProfile]
    func saveProfile(_ profile: TimingAlignmentProfile)
    func deleteProfile(key: String)
}

final class UserDefaultsTimingAlignmentStore: TimingAlignmentPersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let storageKey: String
    private let lock = NSLock()

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "DrumTrainer.timingAlignmentProfiles"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    func loadProfiles() -> [TimingAlignmentProfile] {
        lock.withLock {
            guard let data = defaults.data(forKey: storageKey) else { return [] }
            return (try? JSONDecoder().decode([TimingAlignmentProfile].self, from: data)) ?? []
        }
    }

    func saveProfile(_ profile: TimingAlignmentProfile) {
        lock.withLock {
            var profiles = decodedProfiles()
            profiles.removeAll { $0.key == profile.key }
            profiles.append(profile)
            if let data = try? JSONEncoder().encode(profiles) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }

    func deleteProfile(key: String) {
        lock.withLock {
            var profiles = decodedProfiles()
            profiles.removeAll { $0.key == key }
            if let data = try? JSONEncoder().encode(profiles) {
                defaults.set(data, forKey: storageKey)
            }
        }
    }

    private func decodedProfiles() -> [TimingAlignmentProfile] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([TimingAlignmentProfile].self, from: data)) ?? []
    }
}

struct TimingAlignmentMeasurement: Equatable, Sendable {
    let compensationMilliseconds: Double
    let medianAbsoluteDeviationMilliseconds: Double
    let sampleCount: Int
    let referenceCount: Int

    var missedCount: Int { max(referenceCount - sampleCount, 0) }
}

struct TimingAlignmentCollector: Sendable {
    let source: EventSource
    let voice: DrumVoice?
    private(set) var referenceTimes: [Int64] = []
    private(set) var events: [PerformanceEvent] = []

    mutating func recordReference(_ sessionTimeNanoseconds: Int64) {
        referenceTimes.append(sessionTimeNanoseconds)
    }

    mutating func record(_ event: PerformanceEvent) {
        guard event.source == source else { return }
        if let voice, event.voice != voice { return }
        guard event.voice != .unknown, event.voice != .metronome else { return }
        events.append(event)
    }

    func measurement(maximumOffsetMilliseconds: Double = 400) -> TimingAlignmentMeasurement? {
        let maximumOffset = Int64((maximumOffsetMilliseconds * 1_000_000).rounded())
        var remainingEvents = events.sorted { $0.sessionTimeNanoseconds < $1.sessionTimeNanoseconds }
        var offsets: [Double] = []

        for reference in referenceTimes.sorted() {
            var bestIndex: Int?
            var bestDistance = UInt64.max
            for (index, event) in remainingEvents.enumerated() {
                let distance = absoluteDifference(reference, event.sessionTimeNanoseconds)
                guard distance <= UInt64(maximumOffset), distance < bestDistance else { continue }
                bestIndex = index
                bestDistance = distance
            }
            guard let bestIndex else { continue }
            let event = remainingEvents.remove(at: bestIndex)
            offsets.append(Double(event.sessionTimeNanoseconds - reference) / 1_000_000)
        }

        guard !offsets.isEmpty else { return nil }
        let medianOffset = Self.median(offsets)
        let deviations = offsets.map { abs($0 - medianOffset) }
        return TimingAlignmentMeasurement(
            compensationMilliseconds: medianOffset,
            medianAbsoluteDeviationMilliseconds: Self.median(deviations),
            sampleCount: offsets.count,
            referenceCount: referenceTimes.count
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    private func absoluteDifference(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        lhs >= rhs ? UInt64(bitPattern: lhs &- rhs) : UInt64(bitPattern: rhs &- lhs)
    }
}
