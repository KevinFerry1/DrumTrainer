import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

struct MetronomeTick: Equatable, Sendable {
    let hostTime: UInt64
    let beat: Int
    let isAccent: Bool
}

enum MetronomeSound: String, CaseIterable, Codable, Identifiable, Sendable {
    case cuttingElectronic
    case woodblock
    case cowbell
    case rimshot
    case warmPulse

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cuttingElectronic: "Cutting electronic"
        case .woodblock: "Woodblock"
        case .cowbell: "Cowbell"
        case .rimshot: "Rimshot"
        case .warmPulse: "Warm pulse"
        }
    }

    var guidance: String {
        switch self {
        case .cuttingElectronic: "Bright and easiest to hear through dense cymbals"
        case .woodblock: "Short acoustic-style knock"
        case .cowbell: "Longer metallic tone"
        case .rimshot: "Sharp broadband crack"
        case .warmPulse: "Lower, softer electronic pulse"
        }
    }
}

enum MetronomeGain {
    static let minimumDecibels = -36.0
    static let maximumDecibels = 24.0
    static let extremeBoostThresholdDecibels = 12.0

    static func clamped(_ decibels: Double) -> Double {
        min(max(decibels, minimumDecibels), maximumDecibels)
    }

    static func isExtremeBoost(_ decibels: Double) -> Bool {
        decibels > extremeBoostThresholdDecibels
    }
}

enum KickMonitorSound: String, CaseIterable, Codable, Identifiable, Sendable {
    case studioPunch
    case deepAcoustic
    case tightTrigger
    case electronicSub

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .studioPunch: "Studio punch"
        case .deepAcoustic: "Deep acoustic"
        case .tightTrigger: "Tight trigger"
        case .electronicSub: "Electronic sub"
        }
    }

    var guidance: String {
        switch self {
        case .studioPunch: "Balanced attack and body, similar to a processed e-kit kick"
        case .deepAcoustic: "Rounder shell tone with a longer low-end decay"
        case .tightTrigger: "Short, clicky attack for fast double-kick passages"
        case .electronicSub: "Sustained electronic low end with a softer attack"
        }
    }
}

enum KickMonitorSource: String, CaseIterable, Codable, Identifiable, Sendable {
    case both
    case midi
    case microphone

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .both: "MIDI + microphone"
        case .midi: "E-kit MIDI"
        case .microphone: "Kick microphone"
        }
    }

    func accepts(_ source: EventSource) -> Bool {
        switch self {
        case .both: source == .midi || source == .microphone
        case .midi: source == .midi
        case .microphone: source == .microphone
        }
    }
}

enum KickMonitorDynamics {
    static func gain(for velocity: Double, isVelocitySensitive: Bool) -> Double {
        guard isVelocitySensitive else { return 1 }
        let bounded = min(max(velocity, 0), 1)
        return 0.16 + 0.84 * pow(bounded, 0.72)
    }
}

struct AppOutputLevel: Equatable, Sendable {
    let peakDBFS: Double
    let rmsDBFS: Double
    let limiterReductionDB: Double

    static let silence = AppOutputLevel(peakDBFS: -80, rmsDBFS: -80, limiterReductionDB: 0)
}

enum AudioLevelMeasurement {
    static func decibelsFS(forAmplitude amplitude: Double, floor: Double = -80) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return floor }
        return max(20 * log10(amplitude), floor)
    }
}

struct MetronomeSchedulingHealth: Equatable, Sendable {
    let warningThresholdMilliseconds: Double
    private(set) var scheduledTickCount = 0
    private(set) var atRiskTickCount = 0
    private(set) var lastLeadTimeMilliseconds: Double?
    private(set) var minimumLeadTimeMilliseconds: Double?

    init(warningThresholdMilliseconds: Double = 20) {
        self.warningThresholdMilliseconds = max(warningThresholdMilliseconds, 0)
    }

    mutating func record(
        scheduledHostTime: UInt64,
        currentHostTime: UInt64,
        converter: any HostTimeConverting
    ) {
        let leadMilliseconds: Double
        if scheduledHostTime >= currentHostTime {
            leadMilliseconds = Double(
                converter.nanoseconds(forHostTimeDuration: scheduledHostTime - currentHostTime)
            ) / 1_000_000
        } else {
            leadMilliseconds = -Double(
                converter.nanoseconds(forHostTimeDuration: currentHostTime - scheduledHostTime)
            ) / 1_000_000
        }

        scheduledTickCount += 1
        lastLeadTimeMilliseconds = leadMilliseconds
        minimumLeadTimeMilliseconds = min(minimumLeadTimeMilliseconds ?? leadMilliseconds, leadMilliseconds)
        if leadMilliseconds < warningThresholdMilliseconds {
            atRiskTickCount += 1
        }
    }

    var hasWarning: Bool { atRiskTickCount > 0 }
}

enum MetronomeStatus: Equatable, Sendable {
    case stopped
    case ready
    case running(String)
    case monitoringKicks(String)
    case disconnected(String)
    case error(String)

    var message: String {
        switch self {
        case .stopped: "Metronome is stopped"
        case .ready: "Ready"
        case let .running(name): "Playing through \(name)"
        case let .monitoringKicks(name): "Kick monitoring through \(name)"
        case let .disconnected(name): "\(name) disconnected; choose another output"
        case let .error(message): message
        }
    }
}

enum MetronomeTimeline {
    static func outputLatencyNanoseconds(
        downstreamSeconds: Double,
        hardwareSeconds: Double,
        maximumTrustedSeconds: Double = 0.5
    ) -> UInt64 {
        let maximum = max(maximumTrustedSeconds, 0)
        let downstreamIsValid = downstreamSeconds.isFinite
            && downstreamSeconds >= 0
            && downstreamSeconds <= maximum
        let hardwareIsValid = hardwareSeconds.isFinite
            && hardwareSeconds >= 0
            && hardwareSeconds <= maximum
        let seconds = downstreamIsValid
            ? downstreamSeconds
            : (hardwareIsValid ? hardwareSeconds : 0)
        return UInt64((seconds * 1_000_000_000).rounded())
    }

    static func intervalNanoseconds(bpm: Double) -> UInt64 {
        let boundedBPM = min(max(bpm, 40), 240)
        return UInt64((60_000_000_000 / boundedBPM).rounded())
    }

    static func beatNumber(forTick tick: Int, beatsPerMeasure: Int = 4) -> Int {
        guard beatsPerMeasure > 0 else { return 1 }
        return tick % beatsPerMeasure + 1
    }

    static func presentationHostTime(
        renderHostTime: UInt64,
        outputLatencyNanoseconds: UInt64,
        converter: any HostTimeConverting
    ) -> UInt64 {
        let latencyTicks = converter.hostTime(forNanosecondDuration: outputLatencyNanoseconds)
        let (result, overflow) = renderHostTime.addingReportingOverflow(latencyTicks)
        return overflow ? UInt64.max : result
    }

    static func renderHostTime(
        presentationHostTime: UInt64,
        outputLatencyNanoseconds: UInt64,
        converter: any HostTimeConverting
    ) -> UInt64 {
        let latencyTicks = converter.hostTime(forNanosecondDuration: outputLatencyNanoseconds)
        return presentationHostTime >= latencyTicks ? presentationHostTime - latencyTicks : 0
    }
}

protocol MetronomeControlling: AnyObject {
    func startMonitoring()
    func select(deviceID: AudioDeviceID?)
    func start(bpm: Double)
    func stop()
    func rebuildAudioGraph(completion: @escaping @Sendable () -> Void)
    func updateBPM(_ bpm: Double)
    func updateSound(_ sound: MetronomeSound)
    func updateGainDecibels(_ gain: Double)
    func updateLimiter(enabled: Bool, ceilingDBFS: Double)
    func updateKickMonitoring(enabled: Bool, sound: KickMonitorSound, gainDecibels: Double,
                              velocitySensitive: Bool, retriggerMilliseconds: Double, startAudioIfNeeded: Bool)
    func triggerKick(velocity: Double, eventHostTime: UInt64, respectsRetriggerLockout: Bool)
    func followTempoMap(startPresentationHostTime: UInt64, referenceBeats: [PracticeReferenceBeat])
}

extension MetronomeControlling {
    func triggerKick(velocity: Double, eventHostTime: UInt64) {
        triggerKick(velocity: velocity, eventHostTime: eventHostTime, respectsRetriggerLockout: true)
    }
}

final class MetronomeEngine: MetronomeControlling, @unchecked Sendable {
    private static let kickPolyphony = 6
    private static let kickVelocitySteps = 16
    private static let retirementQueue = DispatchQueue(label: "DrumTrainer.RetiredMetronomeEngine", qos: .utility)

    typealias DevicesHandler = @Sendable ([AudioOutputDevice]) -> Void
    typealias StatusHandler = @Sendable (MetronomeStatus) -> Void
    typealias TickHandler = @Sendable (MetronomeTick) -> Void
    typealias HealthHandler = @Sendable (MetronomeSchedulingHealth) -> Void
    typealias OutputLevelHandler = @Sendable (AppOutputLevel) -> Void
    typealias OutputLatencyHandler = @Sendable (Double) -> Void

    private let onDevicesChanged: DevicesHandler
    private let onStatusChanged: StatusHandler
    private let onTick: TickHandler
    private let onHealthChanged: HealthHandler
    private let onOutputLevelChanged: OutputLevelHandler
    private let onOutputLatencyChanged: OutputLatencyHandler
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private var kickPlayers = (0..<MetronomeEngine.kickPolyphony).map { _ in AVAudioPlayerNode() }
    private var appMixer = AVAudioMixerNode()
    private var limiter = MetronomeEngine.makeLimiter()
    private let engineQueue = DispatchQueue(label: "DrumTrainer.MetronomeEngine", qos: .userInteractive)
    private let listenerQueue = DispatchQueue(label: "DrumTrainer.MetronomeDeviceListener")

    private var timer: DispatchSourceTimer?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private var selectedDeviceID: AudioDeviceID?
    private var selectedDeviceName: String?
    private var bpm = 120.0
    private var sound: MetronomeSound = .cuttingElectronic
    private var gainDecibels = -3.0
    private var kickMonitoringEnabled = false
    private var kickMonitorSound: KickMonitorSound = .studioPunch
    private var kickMonitorGainDecibels = -6.0
    private var kickMonitorVelocitySensitive = true
    private var kickMonitorRetriggerMilliseconds = 30.0
    private var limiterEnabled = true
    private var limiterCeilingDBFS = -1.0
    private var clickFormat: AVAudioFormat?
    private var isGraphConfigured = false
    private var isOutputTapInstalled = false
    private var isRunning = false
    private var generation = 0
    private var nextTickHostTime: UInt64 = 0
    private var tickIndex = 0
    private var normalClick: AVAudioPCMBuffer?
    private var accentClick: AVAudioPCMBuffer?
    private var kickBuffers: [AVAudioPCMBuffer] = []
    private var nextKickPlayerIndex = 0
    private var lastKickEventHostTime: UInt64?
    private var outputPresentationLatencyNanoseconds: UInt64 = 0
    private var schedulingHealth = MetronomeSchedulingHealth()
    private let hostTimeConverter = CoreAudioHostTimeConverter()
    private var referenceBeats: [PracticeReferenceBeat]?
    private var referenceBeatCursor = 0
    private var referenceStartPresentationHostTime: UInt64 = 0

    init(
        onDevicesChanged: @escaping DevicesHandler,
        onStatusChanged: @escaping StatusHandler,
        onTick: @escaping TickHandler,
        onHealthChanged: @escaping HealthHandler,
        onOutputLevelChanged: @escaping OutputLevelHandler = { _ in },
        onOutputLatencyChanged: @escaping OutputLatencyHandler = { _ in }
    ) {
        self.onDevicesChanged = onDevicesChanged
        self.onStatusChanged = onStatusChanged
        self.onTick = onTick
        self.onHealthChanged = onHealthChanged
        self.onOutputLevelChanged = onOutputLevelChanged
        self.onOutputLatencyChanged = onOutputLatencyChanged
        engine.attach(player)
        kickPlayers.forEach(engine.attach)
        engine.attach(appMixer)
        engine.attach(limiter)
    }

    deinit {
        timer?.cancel()
        engine.stop()
        player.stop()
        kickPlayers.forEach { $0.stop() }
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

    func startMonitoring() {
        refreshDevices()
        installDeviceListenerIfNeeded()
        engineQueue.async { [weak self] in
            guard let self else { return }
            if kickMonitoringEnabled, engine.isRunning {
                let outputName = selectedDeviceName ?? Self.defaultOutputDeviceName() ?? "System Default"
                onStatusChanged(.monitoringKicks(outputName))
            } else {
                onStatusChanged(.ready)
            }
        }
    }

    func select(deviceID: AudioDeviceID?) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            let wasRunning = isRunning
            stopAllAudio(publishStatus: false)
            selectedDeviceID = deviceID
            selectedDeviceName = Self.availableDevices().first(where: { $0.id == deviceID })?.name
            if wasRunning {
                beginPlayback()
            } else if kickMonitoringEnabled {
                beginKickMonitoringOnly()
            } else {
                onStatusChanged(.ready)
            }
        }
    }

    func start(bpm: Double) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.bpm = min(max(bpm, 40), 240)
            // AppState never intentionally starts a second exercise while one is
            // active. Avoid stopping every player on an already-idle graph here:
            // AVAudioPlayerNode.stop() can wait forever after a USB route change,
            // which previously stranded this serial queue before beginPlayback().
            if isRunning {
                stopMetronomePlayback(publishStatus: false)
            } else {
                generation += 1
                referenceBeats = nil
                referenceBeatCursor = 0
                timer?.cancel()
                timer = nil
            }
            beginPlayback()
        }
    }

    func stop() {
        engineQueue.async { [weak self] in
            self?.stopMetronomePlayback(publishStatus: true)
        }
    }

    /// A Core Audio teardown can block indefinitely after a USB route failure.
    /// Keep the old engine alive until a background queue can release it, so
    /// replacing a stuck transport never releases AVAudioEngine on the UI thread.
    func retire() {
        Self.retirementQueue.async { [self] in
            stop()
        }
    }

    /// Tears down every AVAudioEngine object instead of reusing a graph that Core Audio may
    /// have left in a non-rendering state after repeated route starts/stops.
    func rebuildAudioGraph(completion: @escaping @Sendable () -> Void = {}) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            stopAllAudio(publishStatus: false)
            removeOutputMeterIfNeeded()

            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            kickPlayers = (0..<Self.kickPolyphony).map { _ in AVAudioPlayerNode() }
            appMixer = AVAudioMixerNode()
            limiter = Self.makeLimiter()
            engine.attach(player)
            kickPlayers.forEach(engine.attach)
            engine.attach(appMixer)
            engine.attach(limiter)

            clickFormat = nil
            isGraphConfigured = false
            normalClick = nil
            accentClick = nil
            kickBuffers = []
            nextKickPlayerIndex = 0
            lastKickEventHostTime = nil
            outputPresentationLatencyNanoseconds = 0
            schedulingHealth = MetronomeSchedulingHealth()
            onOutputLatencyChanged(0)
            onHealthChanged(schedulingHealth)
            onDevicesChanged(Self.availableDevices())
            if kickMonitoringEnabled {
                beginKickMonitoringOnly()
            } else {
                onStatusChanged(.ready)
            }
            completion()
        }
    }

    func updateBPM(_ bpm: Double) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.bpm = min(max(bpm, 40), 240)
            guard isRunning else { return }
            stopMetronomePlayback(publishStatus: false)
            beginPlayback()
        }
    }

    func updateSound(_ sound: MetronomeSound) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.sound = sound
            rebuildClickBuffers()
        }
    }

    func updateGainDecibels(_ gainDecibels: Double) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.gainDecibels = MetronomeGain.clamped(gainDecibels)
            rebuildClickBuffers()
        }
    }

    func updateKickMonitoring(
        enabled: Bool,
        sound: KickMonitorSound,
        gainDecibels: Double,
        velocitySensitive: Bool,
        retriggerMilliseconds: Double,
        startAudioIfNeeded: Bool
    ) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            let wasEnabled = kickMonitoringEnabled
            kickMonitoringEnabled = enabled
            kickMonitorSound = sound
            kickMonitorGainDecibels = min(max(gainDecibels, -36), 6)
            kickMonitorVelocitySensitive = velocitySensitive
            kickMonitorRetriggerMilliseconds = min(max(retriggerMilliseconds, 10), 150)
            rebuildKickBuffers()

            if enabled, startAudioIfNeeded, !engine.isRunning {
                beginKickMonitoringOnly()
            } else if !enabled, wasEnabled, !isRunning {
                stopAllAudio(publishStatus: true)
            }
        }
    }

    func triggerKick(
        velocity: Double,
        eventHostTime: UInt64,
        respectsRetriggerLockout: Bool = true
    ) {
        engineQueue.async { [weak self] in
            guard let self, kickMonitoringEnabled else { return }
            let boundedHostTime = eventHostTime == 0 ? AudioGetCurrentHostTime() : eventHostTime
            if respectsRetriggerLockout,
               let lastKickEventHostTime,
               boundedHostTime <= lastKickEventHostTime
                    || AudioConvertHostTimeToNanos(boundedHostTime - lastKickEventHostTime)
                        < UInt64((kickMonitorRetriggerMilliseconds * 1_000_000).rounded()) {
                return
            }
            lastKickEventHostTime = boundedHostTime

            if !engine.isRunning { beginKickMonitoringOnly() }
            guard engine.isRunning, !kickBuffers.isEmpty else { return }

            let dynamics = KickMonitorDynamics.gain(
                for: velocity,
                isVelocitySensitive: kickMonitorVelocitySensitive
            )
            let bufferIndex = min(
                max(Int((dynamics * Double(Self.kickVelocitySteps - 1)).rounded()), 0),
                kickBuffers.count - 1
            )
            let kickPlayer = kickPlayers[nextKickPlayerIndex]
            nextKickPlayerIndex = (nextKickPlayerIndex + 1) % kickPlayers.count
            if !kickPlayer.isPlaying { kickPlayer.play() }
            kickPlayer.scheduleBuffer(kickBuffers[bufferIndex], at: nil, options: .interrupts)
        }
    }

    func updateLimiter(enabled: Bool, ceilingDBFS: Double) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            limiterEnabled = enabled
            limiterCeilingDBFS = min(max(ceilingDBFS, -12), -0.5)
            configureLimiter()
        }
    }

    func followTempoMap(
        startPresentationHostTime: UInt64,
        referenceBeats: [PracticeReferenceBeat]
    ) {
        engineQueue.async { [weak self] in
            guard let self, isRunning, !referenceBeats.isEmpty else { return }
            generation += 1
            timer?.cancel()
            timer = nil
            // A player-node stop can wait on the USB render thread forever.
            // Pause rendering before clearing the already-scheduled count-in.
            engine.pause()
            player.stop()
            do {
                try engine.start()
            } catch {
                stopAllAudio(publishStatus: false)
                onStatusChanged(.error("Could not restart the click: \(error.localizedDescription)"))
                return
            }
            player.play()
            self.referenceBeats = referenceBeats.sorted {
                $0.offsetNanoseconds == $1.offsetNanoseconds
                    ? $0.beat < $1.beat
                    : $0.offsetNanoseconds < $1.offsetNanoseconds
            }
            referenceBeatCursor = 0
            referenceStartPresentationHostTime = startPresentationHostTime
            schedulingHealth = MetronomeSchedulingHealth()
            onHealthChanged(schedulingHealth)
            startScheduleTimer(generation: generation)
        }
    }

    private func beginPlayback() {
        do {
            try startAudioGraph()

            isRunning = true
            generation += 1
            tickIndex = 0
            referenceBeats = nil
            referenceBeatCursor = 0
            schedulingHealth = MetronomeSchedulingHealth()
            onHealthChanged(schedulingHealth)
            nextTickHostTime = AudioGetCurrentHostTime() + AudioConvertNanosToHostTime(200_000_000)
            startScheduleTimer(generation: generation)
            scheduleAhead(generation: generation)

            let outputName = selectedDeviceName ?? Self.defaultOutputDeviceName() ?? "System Default"
            onStatusChanged(.running(outputName))
        } catch {
            stopAllAudio(publishStatus: false)
            onStatusChanged(.error("Could not start metronome: \(error.localizedDescription)"))
        }
    }

    private func beginKickMonitoringOnly() {
        guard kickMonitoringEnabled else { return }
        do {
            try startAudioGraph()
            isRunning = false
            let outputName = selectedDeviceName ?? Self.defaultOutputDeviceName() ?? "System Default"
            onStatusChanged(.monitoringKicks(outputName))
        } catch {
            stopAllAudio(publishStatus: false)
            onStatusChanged(.error("Could not start kick monitoring: \(error.localizedDescription)"))
        }
    }

    private func startAudioGraph() throws {
        // Replays reuse a healthy, silently rendering graph. Route changes and
        // explicit recovery still stop it, which forces a full configuration here.
        if !engine.isRunning {
            if !isGraphConfigured { try configureEngine() }
            try engine.start()
        }
        player.play()
        kickPlayers.forEach { $0.play() }

        // Both click and kick-monitor players share the same mixer, limiter, and selected
        // hardware output. This latency is presentation-only; a live kick cannot be scheduled
        // ahead of an input event that has not happened yet.
        let downstreamLatency = max(
            appMixer.outputPresentationLatency,
            engine.mainMixerNode.outputPresentationLatency,
            engine.outputNode.presentationLatency
        )
        outputPresentationLatencyNanoseconds = MetronomeTimeline.outputLatencyNanoseconds(
            downstreamSeconds: downstreamLatency,
            hardwareSeconds: engine.outputNode.presentationLatency
        )
        onOutputLatencyChanged(Double(outputPresentationLatencyNanoseconds) / 1_000_000)
    }

    private func configureEngine() throws {
        isGraphConfigured = false
        removeOutputMeterIfNeeded()
        engine.stop()
        engine.reset()
        engine.disconnectNodeOutput(player)
        kickPlayers.forEach(engine.disconnectNodeOutput)
        engine.disconnectNodeOutput(appMixer)
        engine.disconnectNodeOutput(limiter)

        // Resolve System Default explicitly: an existing output unit can otherwise
        // remain bound to the previously selected USB interface.
        if let outputDeviceID = selectedDeviceID ?? Self.defaultOutputDeviceID() {
            guard Self.availableDevices().contains(where: { $0.id == outputDeviceID }) else {
                throw MetronomeEngineError.outputUnavailable(selectedDeviceName ?? "Selected output")
            }
            guard let audioUnit = engine.outputNode.audioUnit else {
                throw MetronomeEngineError.missingAudioUnit
            }
            var mutableDeviceID = outputDeviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else { throw MetronomeEngineError.coreAudio(status) }
        }

        let outputFormat = engine.outputNode.inputFormat(forBus: 0)
        let sampleRate = outputFormat.sampleRate > 0 ? outputFormat.sampleRate : 48_000
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw MetronomeEngineError.invalidFormat
        }

        clickFormat = monoFormat
        rebuildClickBuffers()
        rebuildKickBuffers()
        guard normalClick != nil, accentClick != nil else { throw MetronomeEngineError.invalidFormat }
        guard !kickMonitoringEnabled || !kickBuffers.isEmpty else { throw MetronomeEngineError.invalidFormat }

        configureLimiter()
        engine.connect(player, to: appMixer, fromBus: 0, toBus: 0, format: monoFormat)
        for (index, kickPlayer) in kickPlayers.enumerated() {
            engine.connect(
                kickPlayer,
                to: appMixer,
                fromBus: 0,
                toBus: AVAudioNodeBus(index + 1),
                format: monoFormat
            )
        }
        engine.connect(appMixer, to: limiter, format: monoFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: monoFormat)
        appMixer.outputVolume = 1
        engine.mainMixerNode.outputVolume = 1
        installOutputMeterIfNeeded()
        engine.prepare()
        isGraphConfigured = true
    }

    private func configureLimiter() {
        setLimiterParameter(kDynamicsProcessorParam_Threshold, value: Float(limiterCeilingDBFS - 0.1))
        setLimiterParameter(kDynamicsProcessorParam_HeadRoom, value: 0.1)
        setLimiterParameter(kDynamicsProcessorParam_ExpansionRatio, value: 1)
        setLimiterParameter(kDynamicsProcessorParam_ExpansionThreshold, value: -80)
        setLimiterParameter(kDynamicsProcessorParam_AttackTime, value: 0.001)
        setLimiterParameter(kDynamicsProcessorParam_ReleaseTime, value: 0.05)
        setLimiterParameter(kDynamicsProcessorParam_OverallGain, value: 0)
        limiter.auAudioUnit.shouldBypassEffect = !limiterEnabled
    }

    private func setLimiterParameter(_ parameter: AudioUnitParameterID, value: AudioUnitParameterValue) {
        AudioUnitSetParameter(
            limiter.audioUnit,
            parameter,
            kAudioUnitScope_Global,
            0,
            value,
            0
        )
    }

    private func limiterReductionDecibels() -> Double {
        var value: AudioUnitParameterValue = 0
        let status = AudioUnitGetParameter(
            limiter.audioUnit,
            kDynamicsProcessorParam_CompressionAmount,
            kAudioUnitScope_Global,
            0,
            &value
        )
        return status == noErr ? max(Double(value), 0) : 0
    }

    private static func makeLimiter() -> AVAudioUnitEffect {
        AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_DynamicsProcessor,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        ))
    }

    private func rebuildClickBuffers() {
        guard let clickFormat else { return }
        normalClick = Self.makeClick(
            format: clickFormat,
            sound: sound,
            isAccent: false,
            gainDecibels: gainDecibels
        )
        accentClick = Self.makeClick(
            format: clickFormat,
            sound: sound,
            isAccent: true,
            gainDecibels: gainDecibels
        )
    }

    private func rebuildKickBuffers() {
        guard let clickFormat else { return }
        kickBuffers = (0..<Self.kickVelocitySteps).compactMap { step in
            let normalizedVelocity = Double(step) / Double(Self.kickVelocitySteps - 1)
            return Self.makeKick(
                format: clickFormat,
                sound: kickMonitorSound,
                gainDecibels: kickMonitorGainDecibels,
                dynamicsGain: normalizedVelocity
            )
        }
    }

    private func installOutputMeterIfNeeded() {
        guard !isOutputTapInstalled else { return }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1_024, format: nil) { [weak self] buffer, _ in
            self?.measureOutput(buffer)
        }
        isOutputTapInstalled = true
    }

    private func removeOutputMeterIfNeeded() {
        guard isOutputTapInstalled else { return }
        engine.mainMixerNode.removeTap(onBus: 0)
        isOutputTapInstalled = false
    }

    private func measureOutput(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        var peak = 0.0
        var sumSquares = 0.0
        let channelCount = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        for channel in 0..<channelCount {
            let samples = channels[channel]
            for frame in 0..<frameCount {
                let value = Double(samples[frame])
                peak = max(peak, abs(value))
                sumSquares += value * value
            }
        }
        let sampleCount = max(channelCount * frameCount, 1)
        let rms = sqrt(sumSquares / Double(sampleCount))
        onOutputLevelChanged(AppOutputLevel(
            peakDBFS: AudioLevelMeasurement.decibelsFS(forAmplitude: peak),
            rmsDBFS: AudioLevelMeasurement.decibelsFS(forAmplitude: rms),
            limiterReductionDB: limiterReductionDecibels()
        ))
    }

    private func startScheduleTimer(generation: Int) {
        timer?.cancel()
        let newTimer = DispatchSource.makeTimerSource(queue: engineQueue)
        newTimer.schedule(deadline: .now(), repeating: .milliseconds(80), leeway: .milliseconds(3))
        newTimer.setEventHandler { [weak self] in
            self?.scheduleAhead(generation: generation)
        }
        timer = newTimer
        newTimer.resume()
    }

    private func scheduleAhead(generation: Int) {
        guard isRunning, generation == self.generation else { return }
        if referenceBeats != nil {
            scheduleReferenceBeatsAhead(generation: generation)
            return
        }
        let horizon = AudioGetCurrentHostTime() + AudioConvertNanosToHostTime(750_000_000)
        let interval = AudioConvertNanosToHostTime(MetronomeTimeline.intervalNanoseconds(bpm: bpm))
        var didScheduleTick = false

        while nextTickHostTime <= horizon {
            let beat = MetronomeTimeline.beatNumber(forTick: tickIndex)
            let isAccent = beat == 1
            guard let buffer = isAccent ? accentClick : normalClick else { return }
            let scheduledHostTime = nextTickHostTime
            schedulingHealth.record(
                scheduledHostTime: scheduledHostTime,
                currentHostTime: AudioGetCurrentHostTime(),
                converter: hostTimeConverter
            )
            didScheduleTick = true
            let presentationHostTime = MetronomeTimeline.presentationHostTime(
                renderHostTime: scheduledHostTime,
                outputLatencyNanoseconds: outputPresentationLatencyNanoseconds,
                converter: hostTimeConverter
            )

            player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: scheduledHostTime), options: [])
            publishTickAtPlayback(
                MetronomeTick(hostTime: presentationHostTime, beat: beat, isAccent: isAccent),
                generation: generation
            )

            tickIndex += 1
            nextTickHostTime &+= interval
        }

        if didScheduleTick {
            onHealthChanged(schedulingHealth)
        }
    }

    private func scheduleReferenceBeatsAhead(generation: Int) {
        guard let referenceBeats else { return }
        let now = AudioGetCurrentHostTime()
        let horizon = now + AudioConvertNanosToHostTime(750_000_000)
        var didScheduleTick = false

        while referenceBeatCursor < referenceBeats.count {
            let reference = referenceBeats[referenceBeatCursor]
            let offsetTicks = hostTimeConverter.hostTime(
                forNanosecondDuration: UInt64(max(reference.offsetNanoseconds, 0))
            )
            let (presentationHostTime, overflow) = referenceStartPresentationHostTime
                .addingReportingOverflow(offsetTicks)
            let boundedPresentationTime = overflow ? UInt64.max : presentationHostTime
            let renderHostTime = MetronomeTimeline.renderHostTime(
                presentationHostTime: boundedPresentationTime,
                outputLatencyNanoseconds: outputPresentationLatencyNanoseconds,
                converter: hostTimeConverter
            )
            guard renderHostTime <= horizon else { break }
            guard let buffer = reference.isAccent ? accentClick : normalClick else { return }

            schedulingHealth.record(
                scheduledHostTime: renderHostTime,
                currentHostTime: now,
                converter: hostTimeConverter
            )
            player.scheduleBuffer(buffer, at: AVAudioTime(hostTime: renderHostTime), options: [])
            publishTickAtPlayback(
                MetronomeTick(
                    hostTime: boundedPresentationTime,
                    beat: reference.beat,
                    isAccent: reference.isAccent
                ),
                generation: generation
            )
            referenceBeatCursor += 1
            didScheduleTick = true
        }

        if didScheduleTick { onHealthChanged(schedulingHealth) }
    }

    private func publishTickAtPlayback(_ tick: MetronomeTick, generation: Int) {
        let now = AudioGetCurrentHostTime()
        let delayNanos = tick.hostTime > now ? AudioConvertHostTimeToNanos(tick.hostTime - now) : 0
        engineQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(min(delayNanos, UInt64(Int.max))))) { [weak self] in
            guard let self, isRunning, generation == self.generation else { return }
            onTick(tick)
        }
    }

    private func stopMetronomePlayback(publishStatus: Bool) {
        isRunning = false
        generation += 1
        referenceBeats = nil
        referenceBeatCursor = 0
        timer?.cancel()
        timer = nil
        // Never stop a player node while its USB output graph is rendering.
        // The graph remains configured and can resume on the next attempt.
        if engine.isRunning { engine.pause() }
        player.stop()
        if kickMonitoringEnabled {
            do {
                try engine.start()
                if !kickPlayers.allSatisfy(\.isPlaying) {
                    kickPlayers.forEach { if !$0.isPlaying { $0.play() } }
                }
                if publishStatus {
                    let outputName = selectedDeviceName ?? Self.defaultOutputDeviceName() ?? "System Default"
                    onStatusChanged(.monitoringKicks(outputName))
                }
            } catch {
                onStatusChanged(.error("Could not resume kick monitoring: \(error.localizedDescription)"))
            }
        } else {
            // Kick players render silence when they have no scheduled buffers.
            // Keep them alive with the graph instead of stopping six nodes on
            // every exercise boundary. One of these stop calls was the observed
            // permanent Core Audio deadlock behind the stuck count-in.
            onOutputLevelChanged(.silence)
            if publishStatus { onStatusChanged(.stopped) }
        }
    }

    private func stopAllAudio(publishStatus: Bool) {
        isRunning = false
        generation += 1
        referenceBeats = nil
        referenceBeatCursor = 0
        timer?.cancel()
        timer = nil
        // Stop hardware rendering before touching individual player nodes. A
        // node stop while the USB render thread is active can synchronously wait
        // on AVFAudio's internal queue forever.
        engine.stop()
        isGraphConfigured = false
        player.stop()
        kickPlayers.forEach { $0.stop() }
        onOutputLevelChanged(.silence)
        if publishStatus { onStatusChanged(.stopped) }
    }

    private func refreshDevices() {
        let devices = Self.availableDevices()
        onDevicesChanged(devices)
        engineQueue.async { [weak self] in
            guard let self, let selectedDeviceID else { return }
            guard !devices.contains(where: { $0.id == selectedDeviceID }) else { return }
            let name = selectedDeviceName ?? "Selected output"
            stopAllAudio(publishStatus: false)
            onStatusChanged(.disconnected(name))
        }
    }

    private func installDeviceListenerIfNeeded() {
        guard deviceListener == nil else { return }
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        var address = Self.devicesPropertyAddress
        if AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            listener
        ) == noErr {
            deviceListener = listener
        }
    }

    private static func makeClick(
        format: AVAudioFormat,
        sound: MetronomeSound,
        isAccent: Bool,
        gainDecibels: Double
    ) -> AVAudioPCMBuffer? {
        let duration: Double = switch sound {
        case .cowbell: 0.075
        case .warmPulse: 0.055
        default: 0.03
        }
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let digitalGain = pow(10, gainDecibels / 20)
        var noiseState: UInt32 = isAccent ? 0xA341_316C : 0xC801_3EA4

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let sample: Double
            switch sound {
            case .cuttingElectronic:
                let frequency = isAccent ? 2_150.0 : 1_450.0
                sample = 0.82 * sin(2 * .pi * frequency * time) * exp(-time * 135)
            case .woodblock:
                let fundamental = isAccent ? 1_650.0 : 1_150.0
                sample = 0.72 * (
                    sin(2 * .pi * fundamental * time)
                        + 0.42 * sin(2 * .pi * fundamental * 1.72 * time)
                ) * exp(-time * 105)
            case .cowbell:
                let shift = isAccent ? 1.18 : 1
                sample = 0.48 * (
                    sin(2 * .pi * 540 * shift * time)
                        + sin(2 * .pi * 845 * shift * time)
                ) * exp(-time * 42)
            case .rimshot:
                noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
                let noise = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)
                let tone = sin(2 * .pi * (isAccent ? 2_400 : 1_900) * time)
                sample = (0.52 * noise + 0.38 * tone) * exp(-time * 150)
            case .warmPulse:
                let frequency = isAccent ? 880.0 : 660.0
                sample = 0.68 * (
                    sin(2 * .pi * frequency * time)
                        + 0.25 * sin(2 * .pi * frequency * 2 * time)
                ) * exp(-time * 55)
            }
            samples[frame] = Float(sample * digitalGain)
        }
        return buffer
    }

    private static func makeKick(
        format: AVAudioFormat,
        sound: KickMonitorSound,
        gainDecibels: Double,
        dynamicsGain: Double
    ) -> AVAudioPCMBuffer? {
        let duration: Double = switch sound {
        case .studioPunch: 0.30
        case .deepAcoustic: 0.42
        case .tightTrigger: 0.18
        case .electronicSub: 0.50
        }
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let samples = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = frameCount

        let outputGain = pow(10, min(max(gainDecibels, -36), 6) / 20)
            * min(max(dynamicsGain, 0), 1)
        let parameters: (
            startFrequency: Double,
            endFrequency: Double,
            bodyDecay: Double,
            clickAmount: Double,
            harmonicAmount: Double
        ) = switch sound {
        case .studioPunch:
            (112, 48, 12, 0.26, 0.16)
        case .deepAcoustic:
            (92, 42, 8, 0.13, 0.20)
        case .tightTrigger:
            (138, 57, 21, 0.42, 0.12)
        case .electronicSub:
            (84, 36, 6.5, 0.07, 0.06)
        }
        var phase = 0.0
        var noiseState: UInt32 = 0x6D2B_79F5

        for frame in 0..<Int(frameCount) {
            let time = Double(frame) / format.sampleRate
            let progress = min(time / duration, 1)
            let sweep = pow(progress, sound == .electronicSub ? 0.28 : 0.18)
            let frequency = parameters.startFrequency
                + (parameters.endFrequency - parameters.startFrequency) * sweep
            phase += 2 * .pi * frequency / format.sampleRate
            noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
            let noise = Double(Int32(bitPattern: noiseState)) / Double(Int32.max)

            let body = sin(phase) * exp(-time * parameters.bodyDecay)
            let harmonic = sin(phase * 2.03)
                * exp(-time * parameters.bodyDecay * 1.7)
                * parameters.harmonicAmount
            let beater = noise * exp(-time * 145) * parameters.clickAmount
            let attack = min(time / 0.0015, 1)
            let tailFade = progress > 0.92 ? max((1 - progress) / 0.08, 0) : 1
            samples[frame] = Float((0.78 * body + harmonic + beater) * attack * tailFade * outputGain)
        }
        return buffer
    }

    private static var devicesPropertyAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func availableDevices() -> [AudioOutputDevice] {
        var address = devicesPropertyAddress
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ) == noErr else { return [] }

        let count = Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = Array(repeating: AudioDeviceID(), count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &deviceIDs
        ) == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard hasOutputStreams(deviceID) else { return nil }
            let name = stringProperty(kAudioObjectPropertyName, for: deviceID) ?? "Audio Output \(deviceID)"
            let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID) ?? String(deviceID)
            return AudioOutputDevice(id: deviceID, uid: uid, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func defaultOutputDeviceName() -> String? {
        defaultOutputDeviceID().flatMap { stringProperty(kAudioObjectPropertyName, for: $0) }
    }

    private static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID()
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount, &deviceID
        ) == noErr else { return nil }
        return deviceID == 0 ? nil : deviceID
    }

    private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeOutput,
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

private enum MetronomeEngineError: LocalizedError {
    case missingAudioUnit
    case invalidFormat
    case outputUnavailable(String)
    case coreAudio(OSStatus)

    var errorDescription: String? {
        switch self {
        case .missingAudioUnit: "The audio output unit is unavailable."
        case .invalidFormat: "The selected output has no usable audio format."
        case let .outputUnavailable(name): "\(name) is not available."
        case let .coreAudio(status): "Core Audio returned error \(status)."
        }
    }
}
