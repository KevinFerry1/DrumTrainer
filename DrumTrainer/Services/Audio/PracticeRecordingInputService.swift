import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Captures a dedicated hardware input for saved practice audio. This is kept
/// separate from `AudioInputService` so a kick microphone can continue driving
/// detection while a line input records the drum module's actual sound.
final class PracticeRecordingInputService: @unchecked Sendable {
    typealias StatusHandler = @Sendable (AudioInputStatus) -> Void

    private let recorder: PracticeAudioRecorder
    private let onStatusChanged: StatusHandler
    private let engine = AVAudioEngine()
    private let captureQueue = DispatchQueue(label: "DrumTrainer.PracticeRecordingInput")
    private var isTapInstalled = false

    init(
        recorder: PracticeAudioRecorder,
        onStatusChanged: @escaping StatusHandler
    ) {
        self.recorder = recorder
        self.onStatusChanged = onStatusChanged
    }

    deinit {
        stopCapture()
    }

    func select(device: AudioInputDevice?) {
        captureQueue.async { [weak self] in
            self?.selectOnCaptureQueue(device: device)
        }
    }

    func disconnect(deviceName: String) {
        captureQueue.async { [weak self] in
            guard let self else { return }
            stopCapture()
            onStatusChanged(.disconnected(deviceName))
        }
    }

    private func selectOnCaptureQueue(device: AudioInputDevice?) {
        stopCapture()
        guard let device else {
            onStatusChanged(.stopped)
            return
        }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            onStatusChanged(.permissionDenied)
            return
        }

        onStatusChanged(.starting(device.name))
        do {
            let format = try startCapture(device: device)
            onStatusChanged(.monitoring(
                device.name,
                sampleRate: format.sampleRate,
                channels: Int(format.channelCount)
            ))
        } catch let error as NSError where error.code == Int(kAudioUnitErr_FormatNotSupported) {
            stopCapture()
            onStatusChanged(.error(
                "Could not record \(device.name): its input format is unsupported. Set it to 44.1 or 48 kHz in Audio MIDI Setup."
            ))
        } catch {
            stopCapture()
            onStatusChanged(.error(
                "Could not record \(device.name): \(error.localizedDescription)"
            ))
        }
    }

    private func startCapture(device: AudioInputDevice) throws -> AVAudioFormat {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            throw PracticeRecordingInputError.missingAudioUnit
        }

        var mutableDeviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw PracticeRecordingInputError.coreAudio(status)
        }

        // Match the input hardware exactly. Asking AVAudioEngine to convert the
        // tap here can raise the same native format exception seen with USB mics.
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw PracticeRecordingInputError.invalidFormat
        }

        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, time in
            self?.recorder.append(buffer, time: time, sourceDeviceID: device.id)
        }
        isTapInstalled = true
        engine.prepare()
        try engine.start()
        return format
    }

    private func stopCapture() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        engine.stop()
        engine.reset()
    }
}

private enum PracticeRecordingInputError: LocalizedError {
    case missingAudioUnit
    case invalidFormat
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAudioUnit:
            "The practice recording input is unavailable."
        case .invalidFormat:
            "The practice recording input has no usable channels or sample rate."
        case let .coreAudio(status):
            "Core Audio returned error \(status)."
        }
    }
}
