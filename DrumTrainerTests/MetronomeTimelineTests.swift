import AVFoundation
import AudioToolbox
import XCTest
@testable import DrumTrainer

final class MetronomeTimelineTests: XCTestCase {
    func testOutputMeterMeasuresPCMWithoutAnAttachedAudioGraph() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        buffer.frameLength = 8
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<8 {
            channels[0][frame] = 0.5
            channels[1][frame] = -0.5
        }

        let meter = MetronomeOutputMeter()
        meter.measure(buffer)
        XCTAssertEqual(meter.snapshot().peakDBFS, -6.020_599_913, accuracy: 0.0001)
        XCTAssertEqual(meter.snapshot().rmsDBFS, -6.020_599_913, accuracy: 0.0001)
        XCTAssertEqual(meter.snapshot().limiterReductionDB, 0)

        for channel in 0..<2 {
            for frame in 0..<8 { channels[channel][frame] = 0 }
        }
        meter.measure(buffer)
        XCTAssertEqual(meter.snapshot(), .silence)
        buffer.frameLength = 0
        meter.measure(buffer)
        XCTAssertEqual(meter.snapshot(), .silence)
    }

    func testNativeAudioGraphRemainsResponsiveAcrossMeteredPracticeReplays() throws {
        let probe = NativeMetronomeAudioProbe()
        let transport = MetronomeEngine(
            onDevicesChanged: { _ in },
            onStatusChanged: { probe.recordStatus($0) },
            onTick: { _ in },
            onHealthChanged: { _ in },
            onOutputLevelChanged: { probe.recordMeter($0) },
            audioEngineFactory: { probe.makeEngine() }
        )
        if let failure = probe.setupFailure {
            return XCTFail("Could not configure native manual rendering: \(failure)")
        }

        let rendererStopped = probe.startRendering()
        defer { probe.cancelRendering() }
        let requestedCycles = ProcessInfo.processInfo.environment["DRUMTRAINER_AUDIO_STRESS_CYCLES"]
            .flatMap(Int.init) ?? 100
        let cycles = min(max(requestedCycles, 1), 10_000)

        for attempt in 0..<cycles {
            transport.updateKickMonitoring(
                enabled: true, sound: .studioPunch, gainDecibels: 6,
                velocitySensitive: false, retriggerMilliseconds: 10, startAudioIfNeeded: false
            )
            transport.updateLimiter(enabled: !attempt.isMultiple(of: 3), ceilingDBFS: attempt.isMultiple(of: 2) ? -1 : -6)
            let started = probe.expectStatus(.running)
            transport.start(bpm: attempt.isMultiple(of: 2) ? 120 : 240)
            guard waitForNativeAudio(started, operation: "start attempt \(attempt)") else { return }

            if attempt.isMultiple(of: 5) {
                // Imported-song handoff clears the scheduled count-in on the same native graph.
                transport.followTempoMap(
                    startPresentationHostTime: AudioGetCurrentHostTime() + AudioConvertNanosToHostTime(50_000_000),
                    referenceBeats: [
                        PracticeReferenceBeat(offsetNanoseconds: 0, measure: 1, beat: 1, isAccent: true),
                        PracticeReferenceBeat(offsetNanoseconds: 250_000_000, measure: 1, beat: 2, isAccent: false)
                    ]
                )
            }

            // A real scheduled kick proves PCM traversed the player, mixer, limiter,
            // and tap. This does not depend on wall-clock metronome tick callbacks.
            let audibleRender = probe.expectAudibleRender()
            let audibleMeter = probe.expectAudibleMeter()
            transport.triggerKick(velocity: 1, eventHostTime: 0, respectsRetriggerLockout: false)
            guard waitForNativeAudio(audibleRender, operation: "render attempt \(attempt)"),
                  waitForNativeAudio(audibleMeter, operation: "meter attempt \(attempt)") else { return }

            let keepsKickMonitoring = attempt.isMultiple(of: 2)
            if !keepsKickMonitoring {
                transport.updateKickMonitoring(
                    enabled: false, sound: .studioPunch, gainDecibels: 6,
                    velocitySensitive: false, retriggerMilliseconds: 10, startAudioIfNeeded: false
                )
            }
            let stopped = probe.expectStatus(keepsKickMonitoring ? .monitoringKicks : .stopped)
            transport.stop()
            guard waitForNativeAudio(stopped, operation: "stop attempt \(attempt)") else { return }

            if attempt % 10 == 9 {
                let rebuilt = XCTestExpectation(description: "native audio graph rebuilt")
                transport.rebuildAudioGraph { rebuilt.fulfill() }
                guard waitForNativeAudio(rebuilt, operation: "rebuild after attempt \(attempt)") else { return }
            }
        }

        let shutdown = probe.expectStatus(.stopped)
        transport.updateKickMonitoring(
            enabled: false, sound: .studioPunch, gainDecibels: 6,
            velocitySensitive: false, retriggerMilliseconds: 10, startAudioIfNeeded: false
        )
        transport.stop()
        guard waitForNativeAudio(shutdown, operation: "final stop") else { return }
        probe.cancelRendering()
        guard waitForNativeAudio(rendererStopped, operation: "renderer shutdown") else { return }

        XCTAssertNil(probe.setupFailure)
        XCTAssertTrue(probe.failures.isEmpty, probe.failures.joined(separator: "\n"))
        XCTAssertGreaterThan(probe.renderedFrameCount, 0)
        XCTAssertGreaterThanOrEqual(probe.meterPacketCount, cycles)
        XCTAssertEqual(probe.createdEngineCount, 1 + cycles / 10)
        print("Native audio stress completed: \(cycles) attempts, \(probe.createdEngineCount) engines, \(probe.renderedFrameCount) rendered frames, \(probe.meterPacketCount) meter packets")
    }

    private func waitForNativeAudio(_ expectation: XCTestExpectation, operation: String) -> Bool {
        let completed = XCTWaiter.wait(for: [expectation], timeout: 3) == .completed
        XCTAssertTrue(completed, "Native audio became unresponsive during \(operation)")
        return completed
    }

    func testMetronomeGainAllowsExtremeBoostAndClampsUnsafeValues() {
        XCTAssertEqual(MetronomeGain.clamped(-100), -36)
        XCTAssertEqual(MetronomeGain.clamped(12), 12)
        XCTAssertEqual(MetronomeGain.clamped(24), 24)
        XCTAssertEqual(MetronomeGain.clamped(100), 24)
        XCTAssertFalse(MetronomeGain.isExtremeBoost(12))
        XCTAssertTrue(MetronomeGain.isExtremeBoost(13))
    }

    func testDigitalAmplitudeConvertsToDecibelsFS() {
        XCTAssertEqual(AudioLevelMeasurement.decibelsFS(forAmplitude: 1), 0, accuracy: 0.0001)
        XCTAssertEqual(
            AudioLevelMeasurement.decibelsFS(forAmplitude: 0.5),
            -6.020_599_913,
            accuracy: 0.0001
        )
        XCTAssertEqual(AudioLevelMeasurement.decibelsFS(forAmplitude: 0), -80)
        XCTAssertEqual(AudioLevelMeasurement.decibelsFS(forAmplitude: .nan), -80)
    }

    func testEveryMetronomeSoundHasUserFacingGuidance() {
        XCTAssertEqual(MetronomeSound.allCases.count, 5)
        XCTAssertTrue(MetronomeSound.allCases.allSatisfy {
            !$0.displayName.isEmpty && !$0.guidance.isEmpty
        })
    }

    func testEveryKickMonitorSoundHasUserFacingGuidance() {
        XCTAssertEqual(KickMonitorSound.allCases.count, 4)
        XCTAssertTrue(KickMonitorSound.allCases.allSatisfy {
            !$0.displayName.isEmpty && !$0.guidance.isEmpty
        })
    }

    func testKickMonitorSourceFiltersSyntheticAndUnselectedInputs() {
        XCTAssertTrue(KickMonitorSource.both.accepts(.midi))
        XCTAssertTrue(KickMonitorSource.both.accepts(.microphone))
        XCTAssertFalse(KickMonitorSource.both.accepts(.simulation))
        XCTAssertTrue(KickMonitorSource.midi.accepts(.midi))
        XCTAssertFalse(KickMonitorSource.midi.accepts(.microphone))
        XCTAssertTrue(KickMonitorSource.microphone.accepts(.microphone))
        XCTAssertFalse(KickMonitorSource.microphone.accepts(.midi))
    }

    func testKickMonitorDynamicsPreserveAudibilityAndVelocityOrder() {
        let quiet = KickMonitorDynamics.gain(for: 0, isVelocitySensitive: true)
        let medium = KickMonitorDynamics.gain(for: 0.5, isVelocitySensitive: true)
        let loud = KickMonitorDynamics.gain(for: 1, isVelocitySensitive: true)

        XCTAssertGreaterThan(quiet, 0)
        XCTAssertLessThan(quiet, medium)
        XCTAssertLessThan(medium, loud)
        XCTAssertEqual(loud, 1, accuracy: 0.0001)
        XCTAssertEqual(KickMonitorDynamics.gain(for: 0.1, isVelocitySensitive: false), 1)
    }

    func testSchedulingHealthTracksMinimumLeadAndAtRiskTicks() {
        let converter = LinearHostTimeConverter(nanosecondsPerTick: 1)
        var health = MetronomeSchedulingHealth(warningThresholdMilliseconds: 20)

        health.record(scheduledHostTime: 50_000_000, currentHostTime: 0, converter: converter)
        health.record(scheduledHostTime: 65_000_000, currentHostTime: 50_000_000, converter: converter)
        health.record(scheduledHostTime: 80_000_000, currentHostTime: 85_000_000, converter: converter)

        XCTAssertEqual(health.scheduledTickCount, 3)
        XCTAssertEqual(health.atRiskTickCount, 2)
        XCTAssertEqual(health.lastLeadTimeMilliseconds, -5)
        XCTAssertEqual(health.minimumLeadTimeMilliseconds, -5)
        XCTAssertTrue(health.hasWarning)
    }

    func testSchedulingHealthTreatsThresholdAsStrictlyAtRisk() {
        let converter = LinearHostTimeConverter(nanosecondsPerTick: 1)
        var health = MetronomeSchedulingHealth(warningThresholdMilliseconds: 20)

        health.record(scheduledHostTime: 20_000_000, currentHostTime: 0, converter: converter)

        XCTAssertEqual(health.atRiskTickCount, 0)
        XCTAssertFalse(health.hasWarning)
    }

    func testBeatIntervalsUseTempo() {
        XCTAssertEqual(MetronomeTimeline.intervalNanoseconds(bpm: 120), 500_000_000)
        XCTAssertEqual(MetronomeTimeline.intervalNanoseconds(bpm: 60), 1_000_000_000)
        XCTAssertEqual(MetronomeTimeline.intervalNanoseconds(bpm: 240), 250_000_000)
    }

    func testTempoIsBoundedToSupportedRange() {
        XCTAssertEqual(
            MetronomeTimeline.intervalNanoseconds(bpm: 1),
            MetronomeTimeline.intervalNanoseconds(bpm: 40)
        )
        XCTAssertEqual(
            MetronomeTimeline.intervalNanoseconds(bpm: 999),
            MetronomeTimeline.intervalNanoseconds(bpm: 240)
        )
    }

    func testBeatNumbersRepeatInFourFour() {
        XCTAssertEqual((0..<8).map { MetronomeTimeline.beatNumber(forTick: $0) }, [1, 2, 3, 4, 1, 2, 3, 4])
    }

    func testOutputLatencyUsesValidDownstreamValueAndRejectsStaleValues() {
        XCTAssertEqual(
            MetronomeTimeline.outputLatencyNanoseconds(
                downstreamSeconds: 0.018,
                hardwareSeconds: 0.007
            ),
            18_000_000
        )
        XCTAssertEqual(
            MetronomeTimeline.outputLatencyNanoseconds(
                downstreamSeconds: 12,
                hardwareSeconds: 0.007
            ),
            7_000_000
        )
        XCTAssertEqual(
            MetronomeTimeline.outputLatencyNanoseconds(
                downstreamSeconds: .infinity,
                hardwareSeconds: .nan
            ),
            0
        )
    }

    func testPresentationTimeIncludesSelectedOutputLatency() {
        let presentationTime = MetronomeTimeline.presentationHostTime(
            renderHostTime: 10_000,
            outputLatencyNanoseconds: 25_000_000,
            converter: LinearHostTimeConverter(nanosecondsPerTick: 100)
        )

        XCTAssertEqual(presentationTime, 260_000)
    }

    func testPresentationTimeSaturatesInsteadOfOverflowing() {
        let presentationTime = MetronomeTimeline.presentationHostTime(
            renderHostTime: UInt64.max - 5,
            outputLatencyNanoseconds: 1_000,
            converter: LinearHostTimeConverter(nanosecondsPerTick: 1)
        )

        XCTAssertEqual(presentationTime, UInt64.max)
    }

    func testRenderTimeSubtractsOutputLatencyAndSaturatesAtZero() {
        let converter = LinearHostTimeConverter(nanosecondsPerTick: 100)
        XCTAssertEqual(
            MetronomeTimeline.renderHostTime(
                presentationHostTime: 260_000,
                outputLatencyNanoseconds: 25_000_000,
                converter: converter
            ),
            10_000
        )
        XCTAssertEqual(
            MetronomeTimeline.renderHostTime(
                presentationHostTime: 10,
                outputLatencyNanoseconds: 25_000_000,
                converter: converter
            ),
            0
        )
    }
}

/// Keeps rendering independent of the transport's serial queue so native tap delivery
/// overlaps player stops, limiter edits, and graph replacement just as it does in practice.
private final class NativeMetronomeAudioProbe: @unchecked Sendable {
    enum ExpectedStatus {
        case running, monitoringKicks, stopped

        func matches(_ status: MetronomeStatus) -> Bool {
            switch (self, status) {
            case (.running, .running), (.monitoringKicks, .monitoringKicks), (.stopped, .stopped): true
            default: false
            }
        }
    }

    private let lock = NSLock()
    private var currentEngine: AVAudioEngine?
    private var isCancelled = false
    private var pendingStatus: (ExpectedStatus, XCTestExpectation)?
    private var pendingRender: XCTestExpectation?
    private var pendingMeter: XCTestExpectation?
    private var recordedSetupFailure: String?
    private var recordedFailures: [String] = []
    private var framesRendered = 0
    private var packetsMetered = 0
    private var enginesCreated = 0

    var setupFailure: String? { lock.withLock { recordedSetupFailure } }
    var failures: [String] { lock.withLock { recordedFailures } }
    var renderedFrameCount: Int { lock.withLock { framesRendered } }
    var meterPacketCount: Int { lock.withLock { packetsMetered } }
    var createdEngineCount: Int { lock.withLock { enginesCreated } }

    func makeEngine() -> AVAudioEngine {
        let engine = AVAudioEngine()
        do {
            let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1_024)
        } catch {
            lock.withLock { recordedSetupFailure = error.localizedDescription }
        }
        lock.withLock {
            currentEngine = engine
            enginesCreated += 1
        }
        return engine
    }

    func expectStatus(_ status: ExpectedStatus) -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "native audio status \(status)")
        lock.withLock { pendingStatus = (status, expectation) }
        return expectation
    }

    func expectAudibleRender() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "native audio renders non-silent PCM")
        lock.withLock { pendingRender = expectation }
        return expectation
    }

    func expectAudibleMeter() -> XCTestExpectation {
        let expectation = XCTestExpectation(description: "native audio tap delivers non-silent meter packet")
        lock.withLock { pendingMeter = expectation }
        return expectation
    }

    func recordStatus(_ status: MetronomeStatus) {
        let expectation: XCTestExpectation? = lock.withLock {
            if case let .error(message) = status { recordedFailures.append(message) }
            guard let pendingStatus, pendingStatus.0.matches(status) else { return nil }
            self.pendingStatus = nil
            return pendingStatus.1
        }
        expectation?.fulfill()
    }

    func recordMeter(_ level: AppOutputLevel) {
        let expectation: XCTestExpectation? = lock.withLock {
            packetsMetered += 1
            if !level.peakDBFS.isFinite || !level.rmsDBFS.isFinite || !level.limiterReductionDB.isFinite {
                recordedFailures.append("Non-finite output meter packet: \(level)")
            }
            guard level.peakDBFS > -65, let pendingMeter else { return nil }
            self.pendingMeter = nil
            return pendingMeter
        }
        expectation?.fulfill()
    }

    func startRendering() -> XCTestExpectation {
        let stopped = XCTestExpectation(description: "native audio renderer stops")
        DispatchQueue(label: "DrumTrainerTests.NativeAudioRendering").async { [self] in
            var bufferedEngine: AVAudioEngine?
            var buffer: AVAudioPCMBuffer?
            while !lock.withLock({ isCancelled }) {
                guard let engine = lock.withLock({ currentEngine }), engine.isRunning else {
                    Thread.sleep(forTimeInterval: 0.002)
                    continue
                }
                if bufferedEngine !== engine {
                    buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 1_024)
                    bufferedEngine = engine
                }
                guard let buffer else { break }
                do {
                    let status = try engine.renderOffline(1_024, to: buffer)
                    if status == .success {
                        let isAudible: Bool
                        if let channels = buffer.floatChannelData {
                            isAudible = (0..<Int(buffer.format.channelCount)).contains { channel in
                                (0..<Int(buffer.frameLength)).contains { abs(channels[channel][$0]) > 0.001 }
                            }
                        } else {
                            isAudible = false
                        }
                        let expectation: XCTestExpectation? = lock.withLock {
                            framesRendered += Int(buffer.frameLength)
                            guard isAudible, let pendingRender else { return nil }
                            self.pendingRender = nil
                            return pendingRender
                        }
                        expectation?.fulfill()
                    }
                } catch {
                    // Stop/rebuild may win the race after the isRunning check.
                    let nativeError = error as NSError
                    if nativeError.code != AVAudioEngineManualRenderingError.notRunning.rawValue {
                        lock.withLock { recordedFailures.append("Manual rendering failed: \(error)") }
                    }
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            stopped.fulfill()
        }
        return stopped
    }

    func cancelRendering() {
        lock.withLock { isCancelled = true }
    }
}
