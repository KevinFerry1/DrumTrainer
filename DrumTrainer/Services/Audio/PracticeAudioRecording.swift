import AVFoundation
import AudioToolbox
import Foundation

struct PracticeAudioAsset: Equatable, Sendable {
    let sessionID: UUID
    let url: URL
    let fileSizeBytes: Int64
}

enum PracticeAudioChannelSelection: String, CaseIterable, Identifiable, Sendable {
    case input1
    case input2
    case loopback34

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .input1: "Input 1"
        case .input2: "Input 2"
        case .loopback34: "Loopback 3–4 (headphone mix)"
        }
    }

    var channelIndices: [Int] {
        switch self {
        case .input1: [0]
        case .input2: [1]
        case .loopback34: [2, 3]
        }
    }

    func isAvailable(channelCount: Int) -> Bool {
        channelIndices.allSatisfy { $0 < channelCount }
    }
}

struct PracticeAudioFileStore: Sendable {
    let directoryURL: URL

    init(directoryURL: URL = Self.defaultDirectoryURL()) {
        self.directoryURL = directoryURL
    }

    static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return base
            .appendingPathComponent("DrumTrainer", isDirectory: true)
            .appendingPathComponent("Practice Audio", isDirectory: true)
    }

    func recordingURL(for sessionID: UUID) -> URL {
        directoryURL.appendingPathComponent(sessionID.uuidString).appendingPathExtension("m4a")
    }

    func prepareDirectory(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func asset(for sessionID: UUID, fileManager: FileManager = .default) -> PracticeAudioAsset? {
        let url = recordingURL(for: sessionID)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0 else { return nil }
        return PracticeAudioAsset(sessionID: sessionID, url: url, fileSizeBytes: Int64(size))
    }

    func deleteRecording(for sessionID: UUID, fileManager: FileManager = .default) throws {
        let url = recordingURL(for: sessionID)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func deleteAllRecordings(fileManager: FileManager = .default) throws {
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    func totalSizeBytes(fileManager: FileManager = .default) -> Int64 {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return urls.reduce(into: Int64(0)) { total, url in
            guard url.pathExtension.lowercased() == "m4a",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true else { return }
            total += Int64(values.fileSize ?? 0)
        }
    }
}

final class PracticeAudioRecorder: @unchecked Sendable {
    typealias Completion = @Sendable (PracticeAudioAsset?, String?) -> Void

    private struct RecordingWindow {
        let generation: UInt64
        let sessionID: UUID
        let sourceDeviceID: AudioDeviceID?
        let channelIndices: [Int]?
        let startHostTime: UInt64
        let endHostTime: UInt64
    }

    private final class AudioBufferEnvelope: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer

        init(_ buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }
    }

    private let store: PracticeAudioFileStore
    private let stateLock = NSLock()
    private let writerQueue = DispatchQueue(label: "DrumTrainer.PracticeAudioWriter")
    private var generation: UInt64 = 0
    private var activeWindow: RecordingWindow?
    private var audioFile: AVAudioFile?
    private var writerGeneration: UInt64?
    private var writerSessionID: UUID?
    private var writerError: String?

    init(store: PracticeAudioFileStore = PracticeAudioFileStore()) {
        self.store = store
    }

    func start(
        sessionID: UUID,
        sourceDeviceID: AudioDeviceID? = nil,
        channelIndices: [Int]? = nil,
        startHostTime: UInt64,
        endHostTime: UInt64
    ) throws {
        guard endHostTime > startHostTime else {
            throw PracticeAudioRecordingError.invalidRecordingWindow
        }
        try store.prepareDirectory()
        try? store.deleteRecording(for: sessionID)

        stateLock.lock()
        generation &+= 1
        let nextGeneration = generation
        activeWindow = RecordingWindow(
            generation: nextGeneration,
            sessionID: sessionID,
            sourceDeviceID: sourceDeviceID,
            channelIndices: channelIndices,
            startHostTime: startHostTime,
            endHostTime: endHostTime
        )
        stateLock.unlock()

        writerQueue.sync {
            audioFile = nil
            writerGeneration = nextGeneration
            writerSessionID = sessionID
            writerError = nil
        }
    }

    func append(
        _ buffer: AVAudioPCMBuffer,
        time: AVAudioTime,
        sourceDeviceID: AudioDeviceID? = nil
    ) {
        guard time.isHostTimeValid, buffer.frameLength > 0 else { return }

        stateLock.lock()
        let window = activeWindow
        stateLock.unlock()
        guard let window else { return }
        if let requiredDeviceID = window.sourceDeviceID,
           sourceDeviceID != requiredDeviceID {
            return
        }

        let bufferStart = time.hostTime
        let durationSeconds = Double(buffer.frameLength) / buffer.format.sampleRate
        let durationHostTime = AVAudioTime.hostTime(forSeconds: durationSeconds)
        let bufferEnd = addingWithoutOverflow(bufferStart, durationHostTime)
        guard bufferEnd > window.startHostTime, bufferStart < window.endHostTime else { return }

        let firstFrame = frameOffset(
            from: bufferStart,
            to: max(bufferStart, window.startHostTime),
            sampleRate: buffer.format.sampleRate,
            maximum: buffer.frameLength,
            roundUp: true
        )
        let endFrame = frameOffset(
            from: bufferStart,
            to: min(bufferEnd, window.endHostTime),
            sampleRate: buffer.format.sampleRate,
            maximum: buffer.frameLength,
            roundUp: false
        )
        guard endFrame > firstFrame,
              let copied = Self.copy(
                buffer,
                frames: firstFrame..<endFrame,
                channelIndices: window.channelIndices
              ) else { return }
        let envelope = AudioBufferEnvelope(copied)
        writerQueue.async { [weak self] in
            self?.write(envelope.buffer, for: window)
        }
    }

    func finish(completion: @escaping Completion) {
        stateLock.lock()
        let window = activeWindow
        activeWindow = nil
        stateLock.unlock()
        guard let window else {
            completion(nil, nil)
            return
        }

        writerQueue.async { [weak self] in
            guard let self else { return }
            let error = writerGeneration == window.generation ? writerError : nil
            if writerGeneration == window.generation {
                audioFile = nil
                writerGeneration = nil
                writerSessionID = nil
                writerError = nil
            }
            let asset = error == nil ? store.asset(for: window.sessionID) : nil
            if asset == nil { try? store.deleteRecording(for: window.sessionID) }
            completion(asset, error ?? (asset == nil ? "No microphone audio was received." : nil))
        }
    }

    func cancel() {
        stateLock.lock()
        let window = activeWindow
        activeWindow = nil
        generation &+= 1
        stateLock.unlock()
        guard let window else { return }

        writerQueue.async { [weak self] in
            guard let self else { return }
            if writerSessionID == window.sessionID {
                audioFile = nil
                writerGeneration = nil
                writerSessionID = nil
                writerError = nil
            }
            try? store.deleteRecording(for: window.sessionID)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer, for window: RecordingWindow) {
        guard writerGeneration == window.generation,
              writerSessionID == window.sessionID,
              writerError == nil else { return }
        do {
            if audioFile == nil {
                let channels = Int(buffer.format.channelCount)
                let bitrate = channels == 1 ? 96_000 : 128_000
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: bitrate,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
                ]
                audioFile = try AVAudioFile(
                    forWriting: store.recordingURL(for: window.sessionID),
                    settings: settings,
                    commonFormat: buffer.format.commonFormat,
                    interleaved: buffer.format.isInterleaved
                )
            }
            try audioFile?.write(from: buffer)
        } catch {
            writerError = "Practice audio could not be saved: \(error.localizedDescription)"
            audioFile = nil
        }
    }

    private func frameOffset(
        from bufferStart: UInt64,
        to target: UInt64,
        sampleRate: Double,
        maximum: AVAudioFrameCount,
        roundUp: Bool
    ) -> AVAudioFramePosition {
        guard target > bufferStart else { return 0 }
        let seconds = AVAudioTime.seconds(forHostTime: target - bufferStart)
        let frames = seconds * sampleRate
        let rounded = roundUp ? ceil(frames) : floor(frames)
        return min(max(AVAudioFramePosition(rounded), 0), AVAudioFramePosition(maximum))
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : value
    }

    private static func copy(
        _ source: AVAudioPCMBuffer,
        frames: Range<AVAudioFramePosition>,
        channelIndices: [Int]?
    ) -> AVAudioPCMBuffer? {
        let frameCount = AVAudioFrameCount(frames.count)
        if let channelIndices {
            guard !channelIndices.isEmpty,
                  !source.format.isInterleaved,
                  source.format.commonFormat == .pcmFormatFloat32,
                  channelIndices.allSatisfy({ $0 >= 0 && $0 < Int(source.format.channelCount) }),
                  let sourceChannels = source.floatChannelData,
                  let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: source.format.sampleRate,
                    channels: AVAudioChannelCount(channelIndices.count),
                    interleaved: false
                  ),
                  let destination = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: frameCount
                  ),
                  let destinationChannels = destination.floatChannelData else { return nil }
            destination.frameLength = frameCount
            for (destinationIndex, sourceIndex) in channelIndices.enumerated() {
                memcpy(
                    destinationChannels[destinationIndex],
                    sourceChannels[sourceIndex].advanced(by: Int(frames.lowerBound)),
                    Int(frameCount) * MemoryLayout<Float>.size
                )
            }
            return destination
        }

        guard frameCount > 0,
              let destination = AVAudioPCMBuffer(
                pcmFormat: source.format,
                frameCapacity: frameCount
              ) else { return nil }
        destination.frameLength = frameCount

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            destination.mutableAudioBufferList
        )
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let sourceBuffer = sourceBuffers[index]
            var destinationBuffer = destinationBuffers[index]
            guard let sourceData = sourceBuffer.mData,
                  let destinationData = destinationBuffer.mData,
                  source.frameLength > 0 else { return nil }
            let bytesPerFrame = Int(sourceBuffer.mDataByteSize) / Int(source.frameLength)
            let byteOffset = Int(frames.lowerBound) * bytesPerFrame
            let byteCount = Int(frameCount) * bytesPerFrame
            memcpy(destinationData, sourceData.advanced(by: byteOffset), byteCount)
            destinationBuffer.mDataByteSize = UInt32(byteCount)
            destinationBuffers[index] = destinationBuffer
        }
        return destination
    }
}

@MainActor
final class PracticeAudioPlaybackController: NSObject, ObservableObject {
    @Published private(set) var isReady = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentTime = 0.0
    @Published private(set) var duration = 0.0
    @Published private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var progressTask: Task<Void, Never>?

    func load(url: URL) {
        stop()
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
            isReady = true
            errorMessage = nil
        } catch {
            player = nil
            duration = 0
            currentTime = 0
            isReady = false
            errorMessage = "Could not open this recording: \(error.localizedDescription)"
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            progressTask?.cancel()
            progressTask = nil
        } else {
            if player.currentTime >= max(player.duration - 0.05, 0) {
                player.currentTime = 0
            }
            player.play()
            isPlaying = true
            startProgressUpdates()
        }
        currentTime = player.currentTime
    }

    func seek(to seconds: Double) {
        guard let player else { return }
        player.currentTime = min(max(seconds, 0), player.duration)
        currentTime = player.currentTime
    }

    func stop() {
        progressTask?.cancel()
        progressTask = nil
        player?.stop()
        player = nil
        isPlaying = false
        isReady = false
        currentTime = 0
        duration = 0
    }

    private func startProgressUpdates() {
        progressTask?.cancel()
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled, let self, let player else { return }
                currentTime = player.currentTime
                if !player.isPlaying {
                    isPlaying = false
                    progressTask = nil
                    return
                }
            }
        }
    }
}

private enum PracticeAudioRecordingError: LocalizedError {
    case invalidRecordingWindow

    var errorDescription: String? {
        "The practice audio recording window is invalid."
    }
}
