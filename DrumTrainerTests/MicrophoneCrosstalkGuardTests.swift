import XCTest
@testable import DrumTrainer

final class MicrophoneCrosstalkGuardTests: XCTestCase {
    func testWeakMicrophoneTransientCoincidentWithNonKickMIDIIsSuppressed() {
        var guardrail = MicrophoneCrosstalkGuard()
        guardrail.observeMIDIHit(voice: .snare, sessionTimeNanoseconds: 1_000_000_000)

        XCTAssertTrue(guardrail.shouldSuppressMicrophoneHit(
            amplitude: 0.35,
            threshold: 0.20,
            calibratedWeakestKickAmplitude: 0.55,
            sessionTimeNanoseconds: 1_018_000_000
        ))
    }

    func testStrongSimultaneousCalibratedKickStillPasses() {
        var guardrail = MicrophoneCrosstalkGuard()
        guardrail.observeMIDIHit(voice: .crash1, sessionTimeNanoseconds: 1_000_000_000)

        XCTAssertFalse(guardrail.shouldSuppressMicrophoneHit(
            amplitude: 0.62,
            threshold: 0.20,
            calibratedWeakestKickAmplitude: 0.55,
            sessionTimeNanoseconds: 1_012_000_000
        ))
    }

    func testWeakTransientMatchingCalibratedKickSoundPassesWithMIDIHit() {
        var guardrail = MicrophoneCrosstalkGuard()
        guardrail.observeMIDIHit(voice: .snare, sessionTimeNanoseconds: 1_000_000_000)

        XCTAssertFalse(guardrail.shouldSuppressMicrophoneHit(
            amplitude: 0.31,
            threshold: 0.20,
            calibratedWeakestKickAmplitude: 0.55,
            kickSoundSimilarity: 0.82,
            minimumKickSimilarity: 0.20,
            sessionTimeNanoseconds: 1_010_000_000
        ))
    }

    func testNonCoincidentMicrophoneHitIsNeverSuppressed() {
        var guardrail = MicrophoneCrosstalkGuard()
        guardrail.observeMIDIHit(voice: .highTom, sessionTimeNanoseconds: 1_000_000_000)

        XCTAssertFalse(guardrail.shouldSuppressMicrophoneHit(
            amplitude: 0.25,
            threshold: 0.20,
            calibratedWeakestKickAmplitude: 0.55,
            sessionTimeNanoseconds: 1_080_000_000
        ))
    }

    func testMIDIKickDoesNotVetoMicrophoneKick() {
        var guardrail = MicrophoneCrosstalkGuard()
        guardrail.observeMIDIHit(voice: .kick, sessionTimeNanoseconds: 1_000_000_000)

        XCTAssertFalse(guardrail.shouldSuppressMicrophoneHit(
            amplitude: 0.25,
            threshold: 0.20,
            calibratedWeakestKickAmplitude: 0.55,
            sessionTimeNanoseconds: 1_010_000_000
        ))
    }

    func testGuardCanBeDisabledForDiagnostics() {
        var guardrail = MicrophoneCrosstalkGuard(
            configuration: .init(isEnabled: false)
        )
        guardrail.observeMIDIHit(voice: .snare, sessionTimeNanoseconds: 1_000_000_000)

        XCTAssertFalse(guardrail.shouldSuppressMicrophoneHit(
            amplitude: 0.25,
            threshold: 0.20,
            calibratedWeakestKickAmplitude: 0.55,
            sessionTimeNanoseconds: 1_010_000_000
        ))
    }
}
