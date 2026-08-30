import Foundation

struct MicrophoneCrosstalkGuardConfiguration: Equatable, Sendable {
    var isEnabled = true
    var coincidenceWindowMilliseconds = 50.0
    var midiArrivalGraceMilliseconds = 20.0
    var uncalibratedStrongKickMargin = 0.18
    var calibratedStrongKickRatio = 0.82
    var calibratedStrongKickMargin = 0.08

    var coincidenceWindowNanoseconds: Int64 {
        Int64((coincidenceWindowMilliseconds * 1_000_000).rounded())
    }
}

struct MicrophoneCrosstalkGuard: Sendable {
    var configuration: MicrophoneCrosstalkGuardConfiguration
    private var recentNonKickMIDITimes: [Int64] = []

    init(configuration: MicrophoneCrosstalkGuardConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func observeMIDIHit(voice: DrumVoice, sessionTimeNanoseconds: Int64) {
        guard voice != .kick, voice != .metronome else { return }
        recentNonKickMIDITimes.append(sessionTimeNanoseconds)
        if recentNonKickMIDITimes.count > 64 {
            recentNonKickMIDITimes.removeFirst(recentNonKickMIDITimes.count - 64)
        }
    }

    mutating func shouldSuppressMicrophoneHit(
        amplitude: Double,
        threshold: Double,
        calibratedWeakestKickAmplitude: Double?,
        kickSoundSimilarity: Double? = nil,
        minimumKickSimilarity: Double = 0.20,
        sessionTimeNanoseconds: Int64
    ) -> Bool {
        guard configuration.isEnabled else { return false }
        if let kickSoundSimilarity, kickSoundSimilarity >= minimumKickSimilarity {
            return false
        }
        let window = configuration.coincidenceWindowNanoseconds
        recentNonKickMIDITimes.removeAll { midiTime in
            sessionTimeNanoseconds - midiTime > max(window * 4, 250_000_000)
        }
        let isCoincident = recentNonKickMIDITimes.contains { midiTime in
            absoluteDifference(sessionTimeNanoseconds, midiTime) <= UInt64(max(window, 0))
        }
        guard isCoincident else { return false }

        let strongKickFloor: Double
        if let calibratedWeakestKickAmplitude {
            strongKickFloor = max(
                threshold + configuration.calibratedStrongKickMargin,
                calibratedWeakestKickAmplitude * configuration.calibratedStrongKickRatio
            )
        } else {
            strongKickFloor = threshold + configuration.uncalibratedStrongKickMargin
        }
        return amplitude < min(max(strongKickFloor, threshold), 0.95)
    }

    mutating func reset() {
        recentNonKickMIDITimes.removeAll(keepingCapacity: true)
    }

    private func absoluteDifference(_ lhs: Int64, _ rhs: Int64) -> UInt64 {
        if lhs >= rhs { return UInt64(bitPattern: lhs &- rhs) }
        return UInt64(bitPattern: rhs &- lhs)
    }
}
