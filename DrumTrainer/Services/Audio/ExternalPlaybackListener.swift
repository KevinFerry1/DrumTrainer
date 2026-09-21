import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit
import AudioToolbox

struct PlaybackAudioSource: Identifiable, Equatable, Sendable {
    let id: Int32
    let name: String
}

/// Requires observed quiet before sound, then confirms 20 ms of sound. Reports
/// the first loud sample window, not the later confirmation/callback time.
struct PlaybackOnsetDetector: Sendable {
    let thresholdDBFS: Double
    private(set) var isReady = false
    private(set) var hasTriggered = false
    private var quietDuration = 0.0
    private var loudDuration = 0.0
    private var candidateTime: Double?
    private var previousEnd: Double?

    init(thresholdDBFS: Double) {
        self.thresholdDBFS = thresholdDBFS.isFinite ? min(max(thresholdDBFS, -80), -10) : -45
    }

    /// ScreenCaptureKit can omit buffers for a silent application. The service
    /// calls this only after capture starts and no audio has arrived for 0.5 s.
    mutating func observeSilentCaptureInterval() {
        guard !hasTriggered else { return }
        isReady = true
        quietDuration = 0.3
        loudDuration = 0
        candidateTime = nil
        previousEnd = nil
    }

    mutating func consume(levelDBFS: Double, time: Double, duration: Double) -> Double? {
        guard !hasTriggered, levelDBFS.isFinite, time.isFinite, duration.isFinite,
              duration > 0, duration <= 0.1 else { return nil }
        if let previousEnd, time < previousEnd - 0.001 { return nil }
        if let previousEnd, time - previousEnd > 0.25 {
            quietDuration = 0
            loudDuration = 0
            candidateTime = nil
            isReady = false
        }
        previousEnd = time + duration
        if levelDBFS < thresholdDBFS {
            quietDuration += duration
            loudDuration = 0
            candidateTime = nil
            if quietDuration >= 0.3 { isReady = true }
            return nil
        }
        quietDuration = 0
        guard isReady else { return nil }
        if candidateTime == nil { candidateTime = time }
        loudDuration += duration
        guard loudDuration >= 0.02 else { return nil }
        hasTriggered = true
        return candidateTime
    }
}

@MainActor
protocol ExternalPlaybackListening: AnyObject {
    func sources() async throws -> [PlaybackAudioSource]
    func start(sourceID: Int32, thresholdDBFS: Double,
               onLevel: @escaping @MainActor (Double, Bool) -> Void,
               onOnset: @escaping @MainActor (UInt64) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws
    func stop()
}

@MainActor
final class ExternalPlaybackListener: ExternalPlaybackListening {
    private var stream: SCStream?
    private var output: PlaybackAudioOutput?
    private var requestID: UUID?
    private var silenceTask: Task<Void, Never>?

    func sources() async throws -> [PlaybackAudioSource] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return content.applications
            .filter { $0.processID != ProcessInfo.processInfo.processIdentifier && !$0.applicationName.isEmpty }
            .map { PlaybackAudioSource(id: $0.processID, name: $0.applicationName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start(sourceID: Int32, thresholdDBFS: Double,
               onLevel: @escaping @MainActor (Double, Bool) -> Void,
               onOnset: @escaping @MainActor (UInt64) -> Void,
               onError: @escaping @MainActor (String) -> Void) async throws {
        stop()
        let id = UUID()
        requestID = id
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard requestID == id, !Task.isCancelled else { return }
        guard let app = content.applications.first(where: { $0.processID == sourceID }),
              let display = content.displays.first else {
            throw NSError(domain: "ExternalPlayback", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "The selected app is no longer available. Reload audio sources and select your browser."
            ])
        }
        let filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.captureMicrophone = false
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        // No screen output is registered or retained. Minimize unused video work.
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        var detector = PlaybackOnsetDetector(thresholdDBFS: thresholdDBFS)
        var lastLevelTime = -Double.infinity
        var lastAudioArrival = ContinuousClock.now
        let output = PlaybackAudioOutput(onFrames: { [weak self] frames in
            guard self?.requestID == id else { return }
            lastAudioArrival = .now
            for frame in frames {
                let onset = detector.consume(levelDBFS: frame.level, time: frame.time, duration: frame.duration)
                if frame.time - lastLevelTime >= 0.1 {
                    lastLevelTime = frame.time
                    onLevel(frame.level, detector.isReady)
                }
                if let onset {
                    onOnset(CMClockConvertHostTimeToSystemUnits(CMTime(seconds: onset, preferredTimescale: 1_000_000_000)))
                    return
                }
            }
        }, onError: { [weak self] message in
            guard self?.requestID == id else { return }
            onError(message)
        })
        let stream = SCStream(filter: filter, configuration: configuration, delegate: output)
        self.output = output
        self.stream = stream
        try stream.addStreamOutput(output, type: SCStreamOutputType.audio, sampleHandlerQueue: DispatchQueue(label: "DrumTrainer.externalPlayback"))
        try await stream.startCapture()
        guard requestID == id, !Task.isCancelled else {
            try? await stream.stopCapture()
            return
        }
        lastAudioArrival = .now
        silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                guard self?.requestID == id else { return }
                if lastAudioArrival.duration(to: .now) >= .milliseconds(500) {
                    detector.observeSilentCaptureInterval()
                    onLevel(-120, detector.isReady)
                }
            }
        }
    }

    func stop() {
        requestID = nil
        silenceTask?.cancel()
        silenceTask = nil
        let oldStream = stream
        let oldOutput = output
        stream = nil
        output = nil
        Task {
            try? await oldStream?.stopCapture()
            // Keep the delegate alive until its stream has stopped.
            withExtendedLifetime(oldOutput) {}
        }
    }
}

private struct PlaybackAudioFrame: Sendable {
    let level: Double
    let time: Double
    let duration: Double
}

private final class PlaybackAudioOutput: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
    let onFrames: @MainActor @Sendable ([PlaybackAudioFrame]) -> Void
    let onError: @MainActor @Sendable (String) -> Void

    init(onFrames: @escaping @MainActor @Sendable ([PlaybackAudioFrame]) -> Void,
         onError: @escaping @MainActor @Sendable (String) -> Void) {
        self.onFrames = onFrames
        self.onError = onError
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let message = error.localizedDescription
        Task { @MainActor in onError(message) }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer),
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 1,
              format.mSampleRate > 0 else {
            Task { @MainActor in onError("Unsupported browser audio format. Cancel and reload audio sources.") }
            return
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard timestamp.isValid, timestamp.isNumeric else { return }
        let byteCount = CMBlockBufferGetDataLength(block)
        guard byteCount > 0, byteCount <= 384_000, byteCount % MemoryLayout<Float>.size == 0 else { return }
        var samples = [Float](repeating: 0, count: byteCount / MemoryLayout<Float>.size)
        let status = samples.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: byteCount, destination: $0.baseAddress!)
        }
        guard status == noErr else { return }
        let window = max(Int(format.mSampleRate * 0.005), 1)
        var frames: [PlaybackAudioFrame] = []
        for start in stride(from: 0, to: samples.count, by: window) {
            let end = min(start + window, samples.count)
            var sum = 0.0
            for index in start..<end {
                let value = Double(samples[index])
                guard value.isFinite else { return }
                sum += value * value
            }
            let rms = sqrt(sum / Double(end - start))
            frames.append(PlaybackAudioFrame(
                level: 20 * log10(max(rms, 0.000_001)),
                time: timestamp.seconds + Double(start) / format.mSampleRate,
                duration: Double(end - start) / format.mSampleRate
            ))
        }
        // Only levels/timestamps cross queues. Audio is never saved or replayed.
        Task { @MainActor in onFrames(frames) }
    }
}
