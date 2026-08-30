import XCTest
@testable import DrumTrainer

final class MicrophoneCalibrationTests: XCTestCase {
    private let analyzer = MicrophoneCalibrationAnalyzer()

    func testNoiseAnalysisUsesRobustPercentileAndSuggestsHigherCollectionThreshold() throws {
        let samples = Array(repeating: 0.02, count: 90) + Array(repeating: 0.04, count: 10)

        let estimate = try XCTUnwrap(analyzer.analyzeNoise(samples))

        XCTAssertEqual(estimate.medianLevel, 0.02, accuracy: 0.0001)
        XCTAssertEqual(estimate.percentile95Level, 0.04, accuracy: 0.0001)
        XCTAssertGreaterThan(estimate.collectionThreshold, estimate.percentile95Level)
        XCTAssertEqual(estimate.sampleCount, 100)
    }

    func testStrongHitsProduceGoodProfileAndThresholdBetweenNoiseAndHits() throws {
        let noise = try XCTUnwrap(analyzer.analyzeNoise(Array(repeating: 0.02, count: 100)))
        let profile = try XCTUnwrap(analyzer.makeProfile(
            deviceUID: "snowball-1",
            deviceName: "Blue Snowball",
            noise: noise,
            hitAmplitudes: stride(from: 0.5, through: 0.88, by: 0.02).map { $0 },
            retriggerLockoutMilliseconds: 40,
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1_000)
        ))

        XCTAssertEqual(profile.detectedHitCount, 20)
        XCTAssertEqual(profile.quality, .good)
        XCTAssertGreaterThan(profile.suggestedThreshold, profile.noisePercentile95)
        XCTAssertLessThan(profile.suggestedThreshold, profile.weakestHitAmplitude)
        XCTAssertGreaterThan(profile.signalToNoiseDecibels, 12)
    }

    func testCalibrationBuildsPersonalKickSoundSignatureFromCapturedFeatures() throws {
        let noise = try XCTUnwrap(analyzer.analyzeNoise(Array(repeating: 0.02, count: 100)))
        let features = (0..<20).map { index in
            AudioTransientFeatures(
                spectralCentroidHertz: 620 + Double(index % 4) * 20,
                lowFrequencyRatio: 0.62 + Double(index % 3) * 0.01,
                highFrequencyRatio: 0.10 + Double(index % 2) * 0.01,
                zeroCrossingRate: 0.08,
                decayRatio: 0.42 + Double(index % 3) * 0.02
            )
        }
        let profile = try XCTUnwrap(analyzer.makeProfile(
            deviceUID: "snowball-sound",
            deviceName: "Blue Snowball",
            noise: noise,
            hitAmplitudes: Array(repeating: 0.7, count: 20),
            hitSoundFeatures: features,
            retriggerLockoutMilliseconds: 40
        ))

        XCTAssertEqual(profile.kickSoundSignature?.sampleCount, 20)
        XCTAssertEqual(profile.kickSoundSignature?.centroidHertz ?? 0, 650, accuracy: 0.001)
    }

    func testPoorSignalSeparationIsReported() throws {
        let noise = try XCTUnwrap(analyzer.analyzeNoise(Array(repeating: 0.30, count: 100)))
        let profile = try XCTUnwrap(analyzer.makeProfile(
            deviceUID: "noisy-room",
            deviceName: "Noisy microphone",
            noise: noise,
            hitAmplitudes: Array(repeating: 0.35, count: 20),
            retriggerLockoutMilliseconds: 40
        ))

        XCTAssertEqual(profile.quality, .poor)
        XCTAssertLessThan(profile.signalToNoiseDecibels, 6)
    }

    func testEmptySamplesCannotCreateFalseCalibration() {
        XCTAssertNil(analyzer.analyzeNoise([]))
        let noise = MicrophoneNoiseEstimate(
            medianLevel: 0.02,
            percentile95Level: 0.03,
            collectionThreshold: 0.08,
            sampleCount: 100
        )
        XCTAssertNil(analyzer.makeProfile(
            deviceUID: "device",
            deviceName: "Device",
            noise: noise,
            hitAmplitudes: [],
            retriggerLockoutMilliseconds: 40
        ))
    }

    func testProfilesPersistSeparatelyByStableDeviceUIDAndCanBeDeleted() throws {
        let suiteName = "MicrophoneCalibrationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsMicrophoneCalibrationStore(defaults: defaults)
        let first = makeProfile(uid: "snowball", threshold: 0.18)
        let second = makeProfile(uid: "mac-mic", threshold: 0.42)

        store.saveProfile(first)
        store.saveProfile(second)

        XCTAssertEqual(store.loadProfile(deviceUID: "snowball"), first)
        XCTAssertEqual(store.loadProfile(deviceUID: "mac-mic"), second)
        store.deleteProfile(deviceUID: "snowball")
        XCTAssertNil(store.loadProfile(deviceUID: "snowball"))
        XCTAssertEqual(store.loadProfile(deviceUID: "mac-mic"), second)
    }

    func testCalibrationCountsCloseSecondaryTransientAsPartOfOneStrike() {
        var collector = MicrophoneCalibrationHitCollector(initialLockoutMilliseconds: 40)

        XCTAssertTrue(collector.record(amplitude: 0.8, sessionTimeNanoseconds: 1_000_000_000))
        XCTAssertFalse(collector.record(amplitude: 0.55, sessionTimeNanoseconds: 1_052_000_000))
        XCTAssertTrue(collector.record(amplitude: 0.75, sessionTimeNanoseconds: 1_600_000_000))

        XCTAssertEqual(collector.amplitudes, [0.8, 0.75])
        XCTAssertEqual(collector.suppressedTransientCount, 1)
        XCTAssertEqual(collector.suggestedLockoutMilliseconds, 60)
    }

    func testCalibrationDoesNotRaiseLockoutWhenHitsAreAlreadyClean() {
        var collector = MicrophoneCalibrationHitCollector(initialLockoutMilliseconds: 40)

        for index in 0..<20 {
            XCTAssertTrue(collector.record(
                amplitude: 0.7,
                sessionTimeNanoseconds: Int64(index) * 500_000_000
            ))
        }

        XCTAssertEqual(collector.amplitudes.count, 20)
        XCTAssertEqual(collector.suppressedTransientCount, 0)
        XCTAssertEqual(collector.suggestedLockoutMilliseconds, 40)
    }

    func testTimingAlignmentCollectorFindsMedianLateInputOffset() throws {
        var collector = TimingAlignmentCollector(source: .midi, voice: .openHiHat)
        let offsets: [Int64] = [48, 52, 50, 49, 51, 50, 47, 53]
        for (index, offset) in offsets.enumerated() {
            let reference = Int64(index + 1) * 1_000_000_000
            collector.recordReference(reference)
            collector.record(PerformanceEvent(
                source: .midi,
                voice: .openHiHat,
                hostTime: 0,
                sessionTimeNanoseconds: reference + offset * 1_000_000,
                rawMetadata: .simulated(label: "timing alignment")
            ))
        }

        let measurement = try XCTUnwrap(collector.measurement())
        XCTAssertEqual(measurement.compensationMilliseconds, 50, accuracy: 0.001)
        XCTAssertEqual(measurement.medianAbsoluteDeviationMilliseconds, 1.5, accuracy: 0.001)
        XCTAssertEqual(measurement.sampleCount, 8)
    }

    func testTimingAlignmentCollectorIgnoresWrongSourceAndVoice() {
        var collector = TimingAlignmentCollector(source: .microphone, voice: .kick)
        collector.recordReference(1_000_000_000)
        collector.record(PerformanceEvent(
            source: .midi,
            voice: .kick,
            hostTime: 0,
            sessionTimeNanoseconds: 1_050_000_000,
            rawMetadata: .simulated(label: "wrong source")
        ))
        collector.record(PerformanceEvent(
            source: .microphone,
            voice: .snare,
            hostTime: 0,
            sessionTimeNanoseconds: 1_050_000_000,
            rawMetadata: .simulated(label: "wrong voice")
        ))

        XCTAssertNil(collector.measurement())
    }

    func testTimingAlignmentProfilesPersistPerInputOutputPairing() throws {
        let suiteName = "TimingAlignmentTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsTimingAlignmentStore(defaults: defaults)
        let focusrite = TimingAlignmentProfile(
            id: UUID(),
            source: .midi,
            inputID: "alesis",
            inputName: "Alesis Module",
            outputUID: "focusrite",
            outputName: "Focusrite Solo",
            voice: .openHiHat,
            compensationMilliseconds: 19.5,
            medianAbsoluteDeviationMilliseconds: 4,
            sampleCount: 12,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let speakers = TimingAlignmentProfile(
            id: UUID(),
            source: .midi,
            inputID: "alesis",
            inputName: "Alesis Module",
            outputUID: "speakers",
            outputName: "Mac Speakers",
            voice: .openHiHat,
            compensationMilliseconds: 31,
            medianAbsoluteDeviationMilliseconds: 5,
            sampleCount: 12,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        store.saveProfile(focusrite)
        store.saveProfile(speakers)
        XCTAssertEqual(Set(store.loadProfiles().map(\.key)), [focusrite.key, speakers.key])

        store.deleteProfile(key: focusrite.key)
        XCTAssertEqual(store.loadProfiles(), [speakers])
    }

    private func makeProfile(uid: String, threshold: Double) -> MicrophoneCalibrationProfile {
        MicrophoneCalibrationProfile(
            id: UUID(),
            deviceUID: uid,
            deviceName: uid,
            createdAt: Date(timeIntervalSince1970: 100),
            noiseFloor: 0.02,
            noisePercentile95: 0.03,
            suggestedThreshold: threshold,
            retriggerLockoutMilliseconds: 40,
            detectedHitCount: 20,
            weakestHitAmplitude: 0.5,
            medianHitAmplitude: 0.7,
            signalToNoiseDecibels: 20,
            quality: .good
        )
    }
}
