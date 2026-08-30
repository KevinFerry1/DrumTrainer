import Foundation

enum CalibrationQuality: String, Codable, Equatable, Sendable {
    case good
    case marginal
    case poor

    var displayName: String {
        switch self {
        case .good: "Good separation"
        case .marginal: "Marginal separation"
        case .poor: "Poor separation"
        }
    }
}

struct MicrophoneNoiseEstimate: Equatable, Sendable {
    let medianLevel: Double
    let percentile95Level: Double
    let collectionThreshold: Double
    let sampleCount: Int
}

struct MicrophoneCalibrationHitCollector: Equatable, Sendable {
    private(set) var amplitudes: [Double] = []
    private(set) var soundFeatures: [AudioTransientFeatures] = []
    private(set) var suppressedTransientCount = 0
    private(set) var suggestedLockoutMilliseconds: Double
    private var lastAcceptedSessionTime: Int64?

    private let isolatedHitSpacingNanoseconds: Int64 = 180_000_000
    private let maximumSuggestedLockoutMilliseconds = 60.0
    private let lockoutSafetyMarginMilliseconds = 8.0

    init(initialLockoutMilliseconds: Double) {
        suggestedLockoutMilliseconds = initialLockoutMilliseconds
    }

    @discardableResult
    mutating func record(
        amplitude: Double,
        soundFeatures: AudioTransientFeatures? = nil,
        sessionTimeNanoseconds: Int64
    ) -> Bool {
        if let lastAcceptedSessionTime {
            let spacing = sessionTimeNanoseconds - lastAcceptedSessionTime
            if spacing >= 0, spacing < isolatedHitSpacingNanoseconds {
                suppressedTransientCount += 1
                let spacingMilliseconds = Double(spacing) / 1_000_000
                suggestedLockoutMilliseconds = max(
                    suggestedLockoutMilliseconds,
                    min(
                        maximumSuggestedLockoutMilliseconds,
                        ceil(spacingMilliseconds + lockoutSafetyMarginMilliseconds)
                    )
                )
                return false
            }
        }

        lastAcceptedSessionTime = sessionTimeNanoseconds
        amplitudes.append(min(max(amplitude, 0), 1))
        if let soundFeatures {
            self.soundFeatures.append(soundFeatures)
        }
        return true
    }
}

struct MicrophoneCalibrationProfile: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let deviceUID: String
    let deviceName: String
    let createdAt: Date
    let noiseFloor: Double
    let noisePercentile95: Double
    let suggestedThreshold: Double
    let retriggerLockoutMilliseconds: Double
    let detectedHitCount: Int
    let weakestHitAmplitude: Double
    let medianHitAmplitude: Double
    let signalToNoiseDecibels: Double
    let quality: CalibrationQuality
    let kickSoundSignature: KickSoundSignature?

    init(
        id: UUID,
        deviceUID: String,
        deviceName: String,
        createdAt: Date,
        noiseFloor: Double,
        noisePercentile95: Double,
        suggestedThreshold: Double,
        retriggerLockoutMilliseconds: Double,
        detectedHitCount: Int,
        weakestHitAmplitude: Double,
        medianHitAmplitude: Double,
        signalToNoiseDecibels: Double,
        quality: CalibrationQuality,
        kickSoundSignature: KickSoundSignature? = nil
    ) {
        self.id = id
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.createdAt = createdAt
        self.noiseFloor = noiseFloor
        self.noisePercentile95 = noisePercentile95
        self.suggestedThreshold = suggestedThreshold
        self.retriggerLockoutMilliseconds = retriggerLockoutMilliseconds
        self.detectedHitCount = detectedHitCount
        self.weakestHitAmplitude = weakestHitAmplitude
        self.medianHitAmplitude = medianHitAmplitude
        self.signalToNoiseDecibels = signalToNoiseDecibels
        self.quality = quality
        self.kickSoundSignature = kickSoundSignature
    }
}

struct MicrophoneCalibrationAnalyzer: Sendable {
    private let soundClassifier = KickSoundClassifier()

    func analyzeNoise(_ samples: [Double]) -> MicrophoneNoiseEstimate? {
        guard !samples.isEmpty else { return nil }
        let bounded = samples.map { min(max($0, 0), 1) }.sorted()
        let medianLevel = percentile(0.5, in: bounded)
        let percentile95 = percentile(0.95, in: bounded)
        let collectionThreshold = min(max(max(percentile95 * 2.5, percentile95 + 0.04), 0.05), 0.8)
        return MicrophoneNoiseEstimate(
            medianLevel: medianLevel,
            percentile95Level: percentile95,
            collectionThreshold: collectionThreshold,
            sampleCount: bounded.count
        )
    }

    func makeProfile(
        deviceUID: String,
        deviceName: String,
        noise: MicrophoneNoiseEstimate,
        hitAmplitudes: [Double],
        hitSoundFeatures: [AudioTransientFeatures] = [],
        retriggerLockoutMilliseconds: Double,
        id: UUID = UUID(),
        createdAt: Date = Date()
    ) -> MicrophoneCalibrationProfile? {
        guard !hitAmplitudes.isEmpty else { return nil }
        let hits = hitAmplitudes.map { min(max($0, 0), 1) }.sorted()
        let weakHit = percentile(0.1, in: hits)
        let medianHit = percentile(0.5, in: hits)
        let separation = max(weakHit - noise.percentile95Level, 0)
        let suggestedThreshold = min(max(
            max(noise.percentile95Level + separation * 0.35, noise.percentile95Level + 0.02),
            0.03
        ), 0.95)
        let signalToNoise = 20 * log10(
            max(medianHit, 0.000_001) / max(noise.percentile95Level, 0.000_001)
        )
        let quality: CalibrationQuality = switch signalToNoise {
        case 12...: .good
        case 6...: .marginal
        default: .poor
        }

        return MicrophoneCalibrationProfile(
            id: id,
            deviceUID: deviceUID,
            deviceName: deviceName,
            createdAt: createdAt,
            noiseFloor: noise.medianLevel,
            noisePercentile95: noise.percentile95Level,
            suggestedThreshold: suggestedThreshold,
            retriggerLockoutMilliseconds: retriggerLockoutMilliseconds,
            detectedHitCount: hits.count,
            weakestHitAmplitude: hits.first ?? 0,
            medianHitAmplitude: medianHit,
            signalToNoiseDecibels: signalToNoise,
            quality: quality,
            kickSoundSignature: soundClassifier.makeSignature(from: hitSoundFeatures)
        )
    }

    private func percentile(_ fraction: Double, in sortedValues: [Double]) -> Double {
        guard !sortedValues.isEmpty else { return 0 }
        let position = min(max(fraction, 0), 1) * Double(sortedValues.count - 1)
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        guard lowerIndex != upperIndex else { return sortedValues[lowerIndex] }
        let weight = position - Double(lowerIndex)
        return sortedValues[lowerIndex] * (1 - weight) + sortedValues[upperIndex] * weight
    }
}

protocol MicrophoneCalibrationPersisting: Sendable {
    func loadProfile(deviceUID: String) -> MicrophoneCalibrationProfile?
    func saveProfile(_ profile: MicrophoneCalibrationProfile)
    func deleteProfile(deviceUID: String)
}

final class UserDefaultsMicrophoneCalibrationStore: MicrophoneCalibrationPersisting, @unchecked Sendable {
    private let defaults: UserDefaults
    private let lock = NSLock()
    private let storageKey = "DrumTrainer.microphoneCalibrationProfiles"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func loadProfile(deviceUID: String) -> MicrophoneCalibrationProfile? {
        lock.withLock { loadProfiles()[deviceUID] }
    }

    func saveProfile(_ profile: MicrophoneCalibrationProfile) {
        lock.withLock {
            var profiles = loadProfiles()
            profiles[profile.deviceUID] = profile
            saveProfiles(profiles)
        }
    }

    func deleteProfile(deviceUID: String) {
        lock.withLock {
            var profiles = loadProfiles()
            profiles.removeValue(forKey: deviceUID)
            saveProfiles(profiles)
        }
    }

    private func loadProfiles() -> [String: MicrophoneCalibrationProfile] {
        guard let data = defaults.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: MicrophoneCalibrationProfile].self, from: data)) ?? [:]
    }

    private func saveProfiles(_ profiles: [String: MicrophoneCalibrationProfile]) {
        guard !profiles.isEmpty else {
            defaults.removeObject(forKey: storageKey)
            return
        }
        if let data = try? JSONEncoder().encode(profiles) {
            defaults.set(data, forKey: storageKey)
        }
    }
}
