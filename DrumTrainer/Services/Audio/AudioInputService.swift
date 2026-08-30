import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum MicrophonePermissionState: Equatable, Sendable {
    case unknown
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum AudioInputStatus: Equatable, Sendable {
    case stopped
    case ready
    case starting(String)
    case monitoring(String, sampleRate: Double, channels: Int)
    case disconnected(String)
    case permissionDenied
    case error(String)

    var message: String {
        switch self {
        case .stopped: "Microphone monitoring is stopped"
        case .ready: "Choose an audio input"
        case let .starting(name): "Starting \(name)…"
        case let .monitoring(name, sampleRate, channels):
            "Monitoring \(name) · \(Int(sampleRate)) Hz · \(channels) ch"
        case let .disconnected(name): "\(name) disconnected; reconnect it or choose another input"
        case .permissionDenied: "Microphone access denied; enable DrumTrainer in System Settings > Privacy & Security > Microphone"
        case let .error(message): message
        }
    }

    var isMonitoring: Bool {
        if case .monitoring = self { true } else { false }
    }

    var isStarting: Bool {
        if case .starting = self { true } else { false }
    }
}

final class AudioInputService: @unchecked Sendable {
    typealias DevicesHandler = @Sendable ([AudioInputDevice]) -> Void
    typealias PermissionHandler = @Sendable (MicrophonePermissionState) -> Void
    typealias StatusHandler = @Sendable (AudioInputStatus) -> Void
    typealias LevelHandler = @Sendable (Double) -> Void
    typealias KickHandler = @Sendable (PerformanceEvent) -> Void

    private let timeline: SessionTimeline
    private let onDevicesChanged: DevicesHandler
    private let onPermissionChanged: PermissionHandler
    private let onStatusChanged: StatusHandler
    private let onLevel: LevelHandler
    private let onKick: KickHandler

    private let engine = AVAudioEngine()
    private let captureQueue = DispatchQueue(label: "DrumTrainer.AudioInputCapture")
    private let stateLock = NSLock()
    private let listenerQueue = DispatchQueue(label: "DrumTrainer.AudioDeviceListener")
    private var detector: KickTransientDetector
    private var selectedDeviceID: AudioDeviceID?
    private var selectedDeviceName: String?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var levelBufferCounter = 0
    private var isTapInstalled = false

    init(
        timeline: SessionTimeline,
        configuration: KickDetectorConfiguration,
        onDevicesChanged: @escaping DevicesHandler,
        onPermissionChanged: @escaping PermissionHandler,
        onStatusChanged: @escaping StatusHandler,
        onLevel: @escaping LevelHandler,
        onKick: @escaping KickHandler
    ) {
        self.timeline = timeline
        self.detector = KickTransientDetector(configuration: configuration)
        self.onDevicesChanged = onDevicesChanged
        self.onPermissionChanged = onPermissionChanged
        self.onStatusChanged = onStatusChanged
        self.onLevel = onLevel
        self.onKick = onKick
    }

    deinit {
        stopCapture()
        if let deviceListener {
            var address = Self.devicesPropertyAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                listenerQueue,
                deviceListener
            )
        }
    }

    func start() {
        refreshDevices()
        publishPermissionState()
        installDeviceListenerIfNeeded()
    }

    func requestPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            onPermissionChanged(.authorized)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                guard let self else { return }
                onPermissionChanged(granted ? .authorized : .denied)
                if granted {
                    stateLock.lock()
                    let pendingDeviceID = selectedDeviceID
                    stateLock.unlock()
                    if let pendingDeviceID { select(deviceID: pendingDeviceID) }
                } else {
                    onStatusChanged(.permissionDenied)
                }
            }
        case .denied:
            onPermissionChanged(.denied)
            onStatusChanged(.permissionDenied)
        case .restricted:
            onPermissionChanged(.restricted)
            onStatusChanged(.permissionDenied)
        @unknown default:
            onPermissionChanged(.unknown)
        }
    }

    func select(deviceID: AudioDeviceID?) {
        captureQueue.async { [weak self] in
            self?.selectOnCaptureQueue(deviceID: deviceID)
        }
    }

    private func selectOnCaptureQueue(deviceID: AudioDeviceID?) {
        stopCapture()
        stateLock.lock()
        selectedDeviceID = deviceID
        selectedDeviceName = nil
        stateLock.unlock()

        guard let deviceID else {
            onStatusChanged(.ready)
            return
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            requestPermission()
            onStatusChanged(.error("Grant microphone access, then choose the input again."))
            return
        }

        guard let device = Self.availableDevices().first(where: { $0.id == deviceID }) else {
            onStatusChanged(.disconnected("Selected audio input"))
            return
        }

        onStatusChanged(.starting(device.name))
        do {
            try beginCapture(device: device)
        } catch {
            onStatusChanged(.error("Could not monitor \(device.name): \(error.localizedDescription)"))
        }
    }

    func updateConfiguration(_ configuration: KickDetectorConfiguration) {
        stateLock.lock()
        detector.configuration = configuration
        stateLock.unlock()
    }

    private func beginCapture(device: AudioInputDevice) throws {
        do {
            let format = try startCapture(deviceID: device.id)
            stateLock.lock()
            selectedDeviceID = device.id
            selectedDeviceName = device.name
            stateLock.unlock()
            onStatusChanged(.monitoring(device.name, sampleRate: format.sampleRate, channels: Int(format.channelCount)))
        } catch let error as NSError where error.code == Int(kAudioUnitErr_FormatNotSupported) {
            stopCapture()
            throw AudioInputServiceError.unsupportedDeviceFormat(device.name)
        }
    }

    private func startCapture(deviceID: AudioDeviceID) throws -> AVAudioFormat {
        let inputNode = engine.inputNode
        guard let audioUnit = inputNode.audioUnit else {
            throw AudioInputServiceError.missingAudioUnit
        }

        var mutableDeviceID = deviceID
        let deviceStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &mutableDeviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard deviceStatus == noErr else {
            throw AudioInputServiceError.coreAudio(deviceStatus)
        }

        // AVAudioInputNode requires a tap to match the hardware-side sample rate
        // and channel count. Using its output format can instead reflect the
        // separate output device and raises an uncaught Objective-C exception.
        let format = inputNode.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw AudioInputServiceError.invalidFormat
        }

        stateLock.lock()
        detector.reset()
        stateLock.unlock()

        inputNode.installTap(onBus: 0, bufferSize: 512, format: format) { [weak self] buffer, time in
            self?.process(buffer: buffer, time: time)
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

    private func process(buffer: AVAudioPCMBuffer, time: AVAudioTime) {
        guard time.isHostTimeValid,
              let channels = buffer.floatChannelData,
              buffer.frameLength > 0 else { return }

        stateLock.lock()
        let output = detector.processPCM(
            channels: UnsafePointer(channels),
            channelCount: Int(buffer.format.channelCount),
            frameCount: Int(buffer.frameLength),
            bufferHostTime: time.hostTime,
            sampleRate: buffer.format.sampleRate,
            timeline: timeline
        )
        levelBufferCounter += 1
        let shouldPublishLevel = levelBufferCounter % 2 == 0
        stateLock.unlock()

        if shouldPublishLevel { onLevel(output.peak) }
        for event in output.events { onKick(event) }
    }

    private func refreshDevices() {
        let devices = Self.availableDevices()
        onDevicesChanged(devices)

        stateLock.lock()
        let activeID = selectedDeviceID
        let activeName = selectedDeviceName
        stateLock.unlock()

        if let activeID, !devices.contains(where: { $0.id == activeID }) {
            captureQueue.async { [weak self] in
                self?.stopCapture()
                self?.onStatusChanged(.disconnected(activeName ?? "Selected audio input"))
            }
        }
    }

    private func publishPermissionState() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: onPermissionChanged(.authorized)
        case .notDetermined: onPermissionChanged(.notDetermined)
        case .denied: onPermissionChanged(.denied)
        case .restricted: onPermissionChanged(.restricted)
        @unknown default: onPermissionChanged(.unknown)
        }
    }

    private func installDeviceListenerIfNeeded() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        var address = Self.devicesPropertyAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        )
        if status == noErr {
            deviceListener = listener
        }
    }

    private static var devicesPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func availableDevices() -> [AudioInputDevice] {
        var address = devicesPropertyAddress
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount
        ) == noErr else { return [] }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &byteCount,
            &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasInputStreams(deviceID) else { return nil }
            let name = stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Audio Input \(deviceID)"
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) ?? String(deviceID)
            return AudioInputDevice(id: deviceID, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &byteCount) == noErr && byteCount > 0
    }

    private static func stringProperty(
        _ selector: AudioObjectPropertySelector,
        for deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &byteCount, &value) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }
}

private enum AudioInputServiceError: LocalizedError {
    case missingAudioUnit
    case invalidFormat
    case coreAudio(OSStatus)
    case unsupportedDeviceFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingAudioUnit: "The audio input unit is unavailable."
        case .invalidFormat: "The selected input has no usable channels or sample rate."
        case let .coreAudio(status): "Core Audio returned error \(status)."
        case let .unsupportedDeviceFormat(name):
            "\(name) is using an unsupported stream format. Open Audio MIDI Setup, choose a standard 44.1 or 48 kHz format, then reconnect it."
        }
    }
}
