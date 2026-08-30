import Foundation

struct AudioTransientFeatures: Codable, Equatable, Sendable {
    let spectralCentroidHertz: Double
    let lowFrequencyRatio: Double
    let highFrequencyRatio: Double
    let zeroCrossingRate: Double
    let decayRatio: Double
}

struct KickSoundSignature: Codable, Equatable, Sendable {
    let centroidHertz: Double
    let centroidToleranceHertz: Double
    let lowFrequencyRatio: Double
    let lowFrequencyTolerance: Double
    let highFrequencyRatio: Double
    let highFrequencyTolerance: Double
    let zeroCrossingRate: Double
    let zeroCrossingTolerance: Double
    let decayRatio: Double
    let decayTolerance: Double
    let sampleCount: Int
}

struct KickSoundClassifier: Sendable {
    private let analysisFrequencies = [
        60.0, 85.0, 120.0, 170.0, 240.0, 340.0, 480.0, 680.0,
        960.0, 1_350.0, 1_900.0, 2_700.0, 3_800.0, 5_400.0, 7_600.0, 10_700.0
    ]

    func extractFeatures(samples: [Double], sampleRate: Double) -> AudioTransientFeatures? {
        guard sampleRate > 0, samples.count >= 16 else { return nil }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let centered = samples.map { $0 - mean }
        let nyquist = sampleRate / 2
        let frequencies = analysisFrequencies.filter { $0 < nyquist * 0.92 }
        guard frequencies.count >= 3 else { return nil }

        let powers = frequencies.map { goertzelPower(centered, sampleRate: sampleRate, frequency: $0) }
        let totalPower = max(powers.reduce(0, +), 1e-12)
        let centroid = zip(frequencies, powers).reduce(0) { $0 + $1.0 * $1.1 } / totalPower
        let lowPower = zip(frequencies, powers).reduce(0) { partial, pair in
            partial + (pair.0 <= 340 ? pair.1 : 0)
        }
        let highPower = zip(frequencies, powers).reduce(0) { partial, pair in
            partial + (pair.0 >= 1_900 ? pair.1 : 0)
        }

        var crossings = 0
        for index in 1..<centered.count where (centered[index - 1] >= 0) != (centered[index] >= 0) {
            crossings += 1
        }
        let zeroCrossingRate = Double(crossings) / Double(max(centered.count - 1, 1))

        let segmentLength = max(centered.count / 4, 1)
        let attackRMS = rms(Array(centered.prefix(segmentLength)))
        let tailRMS = rms(Array(centered.suffix(segmentLength)))
        let decayRatio = min(tailRMS / max(attackRMS, 1e-9), 4)

        return AudioTransientFeatures(
            spectralCentroidHertz: centroid,
            lowFrequencyRatio: min(max(lowPower / totalPower, 0), 1),
            highFrequencyRatio: min(max(highPower / totalPower, 0), 1),
            zeroCrossingRate: min(max(zeroCrossingRate, 0), 1),
            decayRatio: min(max(decayRatio, 0), 4)
        )
    }

    func makeSignature(from features: [AudioTransientFeatures]) -> KickSoundSignature? {
        guard features.count >= 8 else { return nil }
        return KickSoundSignature(
            centroidHertz: median(features.map(\.spectralCentroidHertz)),
            centroidToleranceHertz: tolerance(features.map(\.spectralCentroidHertz), minimum: 250),
            lowFrequencyRatio: median(features.map(\.lowFrequencyRatio)),
            lowFrequencyTolerance: tolerance(features.map(\.lowFrequencyRatio), minimum: 0.06),
            highFrequencyRatio: median(features.map(\.highFrequencyRatio)),
            highFrequencyTolerance: tolerance(features.map(\.highFrequencyRatio), minimum: 0.06),
            zeroCrossingRate: median(features.map(\.zeroCrossingRate)),
            zeroCrossingTolerance: tolerance(features.map(\.zeroCrossingRate), minimum: 0.04),
            decayRatio: median(features.map(\.decayRatio)),
            decayTolerance: tolerance(features.map(\.decayRatio), minimum: 0.25),
            sampleCount: features.count
        )
    }

    func similarity(of features: AudioTransientFeatures, to signature: KickSoundSignature) -> Double {
        let distances = [
            normalizedDistance(features.spectralCentroidHertz, signature.centroidHertz, signature.centroidToleranceHertz),
            normalizedDistance(features.lowFrequencyRatio, signature.lowFrequencyRatio, signature.lowFrequencyTolerance),
            normalizedDistance(features.highFrequencyRatio, signature.highFrequencyRatio, signature.highFrequencyTolerance),
            normalizedDistance(features.zeroCrossingRate, signature.zeroCrossingRate, signature.zeroCrossingTolerance),
            normalizedDistance(features.decayRatio, signature.decayRatio, signature.decayTolerance)
        ]
        let meanSquaredDistance = distances.reduce(0) { $0 + $1 * $1 } / Double(distances.count)
        return min(max(exp(-0.5 * meanSquaredDistance), 0), 1)
    }

    private func goertzelPower(_ samples: [Double], sampleRate: Double, frequency: Double) -> Double {
        let omega = 2 * Double.pi * frequency / sampleRate
        let coefficient = 2 * cos(omega)
        var previous = 0.0
        var previous2 = 0.0
        let denominator = Double(max(samples.count - 1, 1))

        for (index, sample) in samples.enumerated() {
            let window = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / denominator)
            let current = sample * window + coefficient * previous - previous2
            previous2 = previous
            previous = current
        }
        return max(previous2 * previous2 + previous * previous - coefficient * previous * previous2, 0)
    }

    private func rms(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        return sqrt(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count))
    }

    private func normalizedDistance(_ value: Double, _ center: Double, _ tolerance: Double) -> Double {
        abs(value - center) / max(tolerance, 1e-9)
    }

    private func tolerance(_ values: [Double], minimum: Double) -> Double {
        let center = median(values)
        let medianAbsoluteDeviation = median(values.map { abs($0 - center) })
        return max(medianAbsoluteDeviation * 3.5, minimum)
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }
}
