import AVFoundation
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

    func testSharedMIDITimingCollectorAcceptsDifferentDrumVoices() throws {
        var collector = TimingAlignmentCollector(source: .midi, voice: nil)
        let voices: [DrumVoice] = [.snare, .openHiHat, .kick, .ride, .snare, .openHiHat]
        let offsets: [Int64] = [31, 29, 30, 32, 28, 30]
        for (index, pair) in zip(voices, offsets).enumerated() {
            let reference = Int64(index + 1) * 1_000_000_000
            collector.recordReference(reference)
            collector.record(PerformanceEvent(
                source: .midi,
                voice: pair.0,
                hostTime: 0,
                sessionTimeNanoseconds: reference + pair.1 * 1_000_000,
                rawMetadata: .simulated(label: "shared MIDI timing alignment")
            ))
        }

        let measurement = try XCTUnwrap(collector.measurement())
        XCTAssertEqual(measurement.compensationMilliseconds, 30, accuracy: 0.001)
        XCTAssertEqual(measurement.sampleCount, voices.count)
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

    func testTimingAlignmentProfilesPersistPerInputOutputAndVoice() throws {
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
        let snare = TimingAlignmentProfile(
            id: UUID(),
            source: .midi,
            inputID: "alesis",
            inputName: "Alesis Module",
            outputUID: "focusrite",
            outputName: "Focusrite Solo",
            voice: .snare,
            compensationMilliseconds: 42,
            medianAbsoluteDeviationMilliseconds: 3,
            sampleCount: 12,
            createdAt: Date(timeIntervalSince1970: 300)
        )

        store.saveProfile(focusrite)
        store.saveProfile(speakers)
        store.saveProfile(snare)
        XCTAssertEqual(Set(store.loadProfiles().map(\.key)), [focusrite.key, speakers.key, snare.key])

        store.deleteProfile(key: focusrite.key)
        XCTAssertEqual(Set(store.loadProfiles().map(\.key)), [speakers.key, snare.key])
    }

    @MainActor
    func testAppStateUsesSharedMIDIProfileAndIgnoresLegacyPerDrumProfiles() {
        let state = AppState(
            clock: FixedHostClock(hostTime: 100),
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1)
        )
        state.midiDevices = [MIDIInputDevice(id: 42, endpoint: 0, name: "Test e-kit")]
        state.selectedMIDIInputID = 42
        let legacy = TimingAlignmentProfile(
            id: UUID(), source: .midi,
            inputID: "42", inputName: "Test e-kit",
            outputUID: "system-default", outputName: "System Default",
            voice: .snare,
            compensationMilliseconds: 48,
            medianAbsoluteDeviationMilliseconds: 3,
            sampleCount: 12,
            createdAt: Date(timeIntervalSince1970: 100)
        )
        let shared = TimingAlignmentProfile(
            id: UUID(), source: .midi,
            inputID: "42", inputName: "Test e-kit",
            outputUID: "system-default", outputName: "System Default",
            voice: .unknown,
            compensationMilliseconds: 30,
            medianAbsoluteDeviationMilliseconds: 2,
            sampleCount: 12,
            createdAt: Date(timeIntervalSince1970: 200)
        )

        state.timingAlignmentProfiles = [legacy]
        XCTAssertNil(state.activeTimingAlignmentProfile)
        XCTAssertTrue(state.hasIgnoredLegacyMIDITimingProfilesForCurrentSetup)

        state.timingAlignmentProfiles.append(shared)
        XCTAssertEqual(state.activeTimingAlignmentProfile, shared)
        XCTAssertEqual(state.timingAlignmentProfilesForCurrentSetup, [shared])
    }

    func testPracticeAudioRecorderWritesOnlyScheduledWindowAsCompressedAAC() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PracticeAudioTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PracticeAudioFileStore(directoryURL: directory)
        let recorder = PracticeAudioRecorder(store: store)
        let sessionID = UUID()
        let sampleRate = 48_000.0
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(sampleRate)
        ))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        for frame in 0..<Int(buffer.frameLength) {
            channel[frame] = Float(sin(Double(frame) * 2 * .pi * 220 / sampleRate) * 0.2)
        }

        let bufferStart = AVAudioTime.hostTime(forSeconds: 10)
        let recordingStart = bufferStart + AVAudioTime.hostTime(forSeconds: 0.25)
        let recordingEnd = bufferStart + AVAudioTime.hostTime(forSeconds: 0.75)
        try recorder.start(
            sessionID: sessionID,
            sourceDeviceID: 91,
            startHostTime: recordingStart,
            endHostTime: recordingEnd
        )
        recorder.append(
            buffer,
            time: AVAudioTime(hostTime: bufferStart),
            sourceDeviceID: 90
        )
        recorder.append(
            buffer,
            time: AVAudioTime(hostTime: bufferStart),
            sourceDeviceID: 91
        )
        let result = await withCheckedContinuation { continuation in
            recorder.finish { asset, error in
                continuation.resume(returning: (asset, error))
            }
        }

        XCTAssertNil(result.1)
        let asset = try XCTUnwrap(result.0)
        XCTAssertGreaterThan(asset.fileSizeBytes, 1_000)
        XCTAssertLessThan(asset.fileSizeBytes, 100_000)
        XCTAssertEqual(store.totalSizeBytes(), asset.fileSizeBytes)
        let player = try AVAudioPlayer(contentsOf: asset.url)
        XCTAssertEqual(player.duration, 0.5, accuracy: 0.06)

        try store.deleteRecording(for: sessionID)
        XCTAssertNil(store.asset(for: sessionID))
        XCTAssertEqual(store.totalSizeBytes(), 0)
    }

    func testPracticeAudioRecorderExtractsScarlettLoopbackPair() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PracticeLoopbackTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PracticeAudioFileStore(directoryURL: directory)
        let recorder = PracticeAudioRecorder(store: store)
        let sessionID = UUID()
        let sampleRate = 48_000.0
        let layout = try XCTUnwrap(AVAudioChannelLayout(
            layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 4
        ))
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            interleaved: false,
            channelLayout: layout
        ))
        let frameCount = AVAudioFrameCount(4_800)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        buffer.frameLength = frameCount
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<4 {
            for frame in 0..<Int(frameCount) {
                channels[channel][frame] = channel >= 2 ? 0.2 : 0
            }
        }

        let start = AVAudioTime.hostTime(forSeconds: 20)
        try recorder.start(
            sessionID: sessionID,
            sourceDeviceID: 101,
            channelIndices: PracticeAudioChannelSelection.loopback34.channelIndices,
            startHostTime: start,
            endHostTime: start + AVAudioTime.hostTime(forSeconds: 0.1)
        )
        recorder.append(
            buffer,
            time: AVAudioTime(hostTime: start),
            sourceDeviceID: 101
        )
        let result = await withCheckedContinuation { continuation in
            recorder.finish { asset, error in
                continuation.resume(returning: (asset, error))
            }
        }

        XCTAssertNil(result.1)
        let asset = try XCTUnwrap(result.0)
        let player = try AVAudioPlayer(contentsOf: asset.url)
        XCTAssertEqual(player.numberOfChannels, 2)
        XCTAssertEqual(player.duration, 0.1, accuracy: 0.03)
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
