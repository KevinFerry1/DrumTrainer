import Foundation

struct KickDetectorConfiguration: Equatable, Sendable {
    var threshold: Double = 0.45
    var retriggerLockoutMilliseconds: Double = 40
    var rearmThresholdRatio: Double = 0.35
    var rearmQuietMilliseconds: Double = 12

    var lockoutNanoseconds: Int64 {
        Int64(retriggerLockoutMilliseconds * 1_000_000)
    }
}

struct KickTransientDetector: Sendable {
    var configuration: KickDetectorConfiguration
    private var wasAboveThreshold = false
    private var isArmed = true
    private var quietFrameCount = 0
    private var lastHitSessionTime: Int64?
    private var analysisSamples: [Double] = []
    private var analysisStartFrame: Int64 = 0
    private var nextAnalysisFrame: Int64 = 0
    private var analysisSampleRate: Double?
    private var pendingHits: [PendingHit] = []
    private let soundClassifier = KickSoundClassifier()

    private struct PendingHit: Sendable {
        let onsetFrame: Int64
        let event: PerformanceEvent
    }

    init(configuration: KickDetectorConfiguration = .init()) {
        self.configuration = configuration
    }

    mutating func processEnvelope(
        _ samples: [Double],
        bufferHostTime: UInt64,
        sampleRate: Double,
        timeline: SessionTimeline
    ) -> [PerformanceEvent] {
        guard sampleRate > 0 else { return [] }
        var detected: [PerformanceEvent] = []

        for (frameOffset, rawSample) in samples.enumerated() {
            let amplitude = min(max(rawSample, 0), 1)
            let frameNanoseconds = UInt64((Double(frameOffset) / sampleRate) * 1_000_000_000)
            let hitHostTime = timeline.hostTime(addingNanoseconds: frameNanoseconds, to: bufferHostTime)
            let hitSessionTime = timeline.sessionTimeNanoseconds(for: hitHostTime)

            if registerSample(amplitude, sessionTime: hitSessionTime, sampleRate: sampleRate) {
                    let availableRange = max(1 - configuration.threshold, 0.000_001)
                    let confidence = min(max(0.5 + 0.5 * ((amplitude - configuration.threshold) / availableRange), 0), 1)
                    detected.append(
                        PerformanceEvent(
                            source: .microphone,
                            voice: .kick,
                            hostTime: hitHostTime,
                            sessionTimeNanoseconds: hitSessionTime,
                            confidence: confidence,
                            rawMetadata: .microphone(
                                amplitude: amplitude,
                                threshold: configuration.threshold,
                                frameOffset: frameOffset
                            )
                        )
                    )
            }
        }

        return detected
    }

    mutating func processPCM(
        channels: UnsafePointer<UnsafeMutablePointer<Float>>,
        channelCount: Int,
        frameCount: Int,
        bufferHostTime: UInt64,
        sampleRate: Double,
        timeline: SessionTimeline
    ) -> (events: [PerformanceEvent], peak: Double) {
        guard sampleRate > 0, channelCount > 0, frameCount > 0 else { return ([], 0) }
        if let analysisSampleRate, abs(analysisSampleRate - sampleRate) > 0.5 {
            reset()
        }
        analysisSampleRate = sampleRate
        var peak = 0.0

        for frameOffset in 0..<frameCount {
            var amplitude = 0.0
            var monoSample = 0.0
            for channel in 0..<channelCount {
                let sample = Double(channels[channel][frameOffset])
                amplitude = max(amplitude, abs(sample))
                monoSample += sample
            }
            monoSample /= Double(channelCount)
            amplitude = min(amplitude, 1)
            peak = max(peak, amplitude)
            let analysisFrame = nextAnalysisFrame
            analysisSamples.append(monoSample)
            nextAnalysisFrame += 1
            let frameNanoseconds = UInt64((Double(frameOffset) / sampleRate) * 1_000_000_000)
            let hitHostTime = timeline.hostTime(addingNanoseconds: frameNanoseconds, to: bufferHostTime)
            let hitSessionTime = timeline.sessionTimeNanoseconds(for: hitHostTime)

            if registerSample(amplitude, sessionTime: hitSessionTime, sampleRate: sampleRate) {
                let availableRange = max(1 - configuration.threshold, 0.000_001)
                let confidence = min(max(0.5 + 0.5 * ((amplitude - configuration.threshold) / availableRange), 0), 1)
                pendingHits.append(
                    PendingHit(
                        onsetFrame: analysisFrame,
                        event: PerformanceEvent(
                            source: .microphone,
                            voice: .kick,
                            hostTime: hitHostTime,
                            sessionTimeNanoseconds: hitSessionTime,
                            confidence: confidence,
                            rawMetadata: .microphone(
                                amplitude: amplitude,
                                threshold: configuration.threshold,
                                frameOffset: frameOffset
                            )
                        )
                    )
                )
            }
        }

        let detected = resolvePendingHits(sampleRate: sampleRate)
        trimAnalysisHistory(sampleRate: sampleRate)
        return (detected, peak)
    }

    mutating func reset() {
        wasAboveThreshold = false
        isArmed = true
        quietFrameCount = 0
        lastHitSessionTime = nil
        analysisSamples.removeAll(keepingCapacity: true)
        analysisStartFrame = 0
        nextAnalysisFrame = 0
        analysisSampleRate = nil
        pendingHits.removeAll(keepingCapacity: true)
    }

    private mutating func resolvePendingHits(sampleRate: Double) -> [PerformanceEvent] {
        let preRollFrames = Int64(max((sampleRate * 0.002).rounded(), 1))
        let postRollFrames = Int64(max((sampleRate * 0.014).rounded(), 16))
        var resolved: [PerformanceEvent] = []
        var unresolved: [PendingHit] = []

        for pending in pendingHits {
            guard nextAnalysisFrame > pending.onsetFrame + postRollFrames else {
                unresolved.append(pending)
                continue
            }
            let firstFrame = max(pending.onsetFrame - preRollFrames, analysisStartFrame)
            let lastFrame = min(pending.onsetFrame + postRollFrames, nextAnalysisFrame - 1)
            let firstIndex = Int(firstFrame - analysisStartFrame)
            let lastIndex = Int(lastFrame - analysisStartFrame)
            guard firstIndex >= 0, lastIndex >= firstIndex, lastIndex < analysisSamples.count else {
                unresolved.append(pending)
                continue
            }
            let window = Array(analysisSamples[firstIndex...lastIndex])
            let features = soundClassifier.extractFeatures(samples: window, sampleRate: sampleRate)
            let event = pending.event
            resolved.append(PerformanceEvent(
                id: event.id,
                sessionID: event.sessionID,
                source: event.source,
                voice: event.voice,
                hostTime: event.hostTime,
                sessionTimeNanoseconds: event.sessionTimeNanoseconds,
                velocity: event.velocity,
                confidence: event.confidence,
                rawMetadata: event.rawMetadata,
                audioFeatures: features
            ))
        }
        pendingHits = unresolved
        return resolved
    }

    private mutating func trimAnalysisHistory(sampleRate: Double) {
        let preRollFrames = Int64(max((sampleRate * 0.002).rounded(), 1))
        let fallbackHistory = Int64(max((sampleRate * 0.050).rounded(), 64))
        let earliestNeeded = pendingHits.map { $0.onsetFrame - preRollFrames }.min()
            ?? (nextAnalysisFrame - fallbackHistory)
        let keepFrom = max(min(earliestNeeded, nextAnalysisFrame), analysisStartFrame)
        let removeCount = Int(keepFrom - analysisStartFrame)
        guard removeCount > 0 else { return }
        analysisSamples.removeFirst(min(removeCount, analysisSamples.count))
        analysisStartFrame = keepFrom
    }

    private mutating func registerSample(
        _ amplitude: Double,
        sessionTime: Int64,
        sampleRate: Double
    ) -> Bool {
        let threshold = min(max(configuration.threshold, 0), 1)
        let isAboveThreshold = amplitude >= threshold
        let outsideLockout = lastHitSessionTime.map {
            sessionTime - $0 >= configuration.lockoutNanoseconds
        } ?? true

        if !isArmed {
            let rearmLevel = threshold * min(max(configuration.rearmThresholdRatio, 0.05), 0.95)
            if amplitude <= rearmLevel {
                quietFrameCount += 1
            } else {
                quietFrameCount = 0
            }

            let requiredQuietFrames = max(
                Int((configuration.rearmQuietMilliseconds / 1_000 * sampleRate).rounded(.up)),
                1
            )
            if outsideLockout && quietFrameCount >= requiredQuietFrames {
                isArmed = true
            }
        }

        let detected = isArmed && outsideLockout && isAboveThreshold && !wasAboveThreshold
        if detected {
            lastHitSessionTime = sessionTime
            isArmed = false
            quietFrameCount = 0
        }
        wasAboveThreshold = isAboveThreshold
        return detected
    }
}
