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
    case disconnected(String)
    case error(String)

    var message: String {
        switch self {
        case .stopped: "Metronome is stopped"
        case .ready: "Ready"
        case let .running(name): "Playing through \(name)"
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

final class MetronomeEngine: @unchecked Sendable {
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
    private var limiterEnabled = true
    private var limiterCeilingDBFS = -1.0
    private var clickFormat: AVAudioFormat?
    private var isOutputTapInstalled = false
    private var isRunning = false
    private var generation = 0
    private var nextTickHostTime: UInt64 = 0
    private var tickIndex = 0
    private var normalClick: AVAudioPCMBuffer?
    private var accentClick: AVAudioPCMBuffer?
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
        engine.attach(limiter)
    }

    deinit {
        timer?.cancel()
        player.stop()
        engine.stop()
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
        onStatusChanged(.ready)
    }

    func select(deviceID: AudioDeviceID?) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            let wasRunning = isRunning
            stopPlayback(publishStatus: false)
            selectedDeviceID = deviceID
            selectedDeviceName = Self.availableDevices().first(where: { $0.id == deviceID })?.name
            if wasRunning {
                beginPlayback()
            } else {
                onStatusChanged(.ready)
            }
        }
    }

    func start(bpm: Double) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.bpm = min(max(bpm, 40), 240)
            stopPlayback(publishStatus: false)
            beginPlayback()
        }
    }

    func stop() {
        engineQueue.async { [weak self] in
            self?.stopPlayback(publishStatus: true)
        }
    }

    /// Tears down every AVAudioEngine object instead of reusing a graph that Core Audio may
    /// have left in a non-rendering state after repeated route starts/stops.
    func rebuildAudioGraph(completion: @escaping @Sendable () -> Void = {}) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            stopPlayback(publishStatus: false)
            removeOutputMeterIfNeeded()

            engine = AVAudioEngine()
            player = AVAudioPlayerNode()
            limiter = Self.makeLimiter()
            engine.attach(player)
            engine.attach(limiter)

            clickFormat = nil
            normalClick = nil
            accentClick = nil
            outputPresentationLatencyNanoseconds = 0
            schedulingHealth = MetronomeSchedulingHealth()
            onOutputLatencyChanged(0)
            onHealthChanged(schedulingHealth)
            onDevicesChanged(Self.availableDevices())
            onStatusChanged(.ready)
            completion()
        }
    }

    func updateBPM(_ bpm: Double) {
        engineQueue.async { [weak self] in
            guard let self else { return }
            self.bpm = min(max(bpm, 40), 240)
            guard isRunning else { return }
            stopPlayback(publishStatus: false)
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
            self.gainDecibels = min(max(gainDecibels, -36), 12)
            rebuildClickBuffers()
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
            player.stop()
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
            try configureEngine()
            try engine.start()
            player.play()

            // The player's downstream presentation latency includes the mixer/effect chain
            // plus the selected output hardware. This is the path the scheduled click follows.
            let downstreamLatency = max(
                player.outputPresentationLatency,
                engine.mainMixerNode.outputPresentationLatency,
                engine.outputNode.presentationLatency
            )
            outputPresentationLatencyNanoseconds = MetronomeTimeline.outputLatencyNanoseconds(
                downstreamSeconds: downstreamLatency,
                hardwareSeconds: engine.outputNode.presentationLatency
            )
            onOutputLatencyChanged(Double(outputPresentationLatencyNanoseconds) / 1_000_000)

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
            stopPlayback(publishStatus: false)
            onStatusChanged(.error("Could not start metronome: \(error.localizedDescription)"))
        }
    }

    private func configureEngine() throws {
        removeOutputMeterIfNeeded()
        engine.stop()
        engine.reset()
        engine.disconnectNodeOutput(player)
        engine.disconnectNodeOutput(limiter)

        if let selectedDeviceID {
            guard Self.availableDevices().contains(where: { $0.id == selectedDeviceID }) else {
                throw MetronomeEngineError.outputUnavailable(selectedDeviceName ?? "Selected output")
            }
            guard let audioUnit = engine.outputNode.audioUnit else {
                throw MetronomeEngineError.missingAudioUnit
            }
            var mutableDeviceID = selectedDeviceID
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
        guard normalClick != nil, accentClick != nil else { throw MetronomeEngineError.invalidFormat }

        configureLimiter()
        engine.connect(player, to: limiter, format: monoFormat)
        engine.connect(limiter, to: engine.mainMixerNode, format: monoFormat)
        engine.mainMixerNode.outputVolume = 1
        installOutputMeterIfNeeded()
        engine.prepare()
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

    private func stopPlayback(publishStatus: Bool) {
        isRunning = false
        generation += 1
        referenceBeats = nil
        referenceBeatCursor = 0
        timer?.cancel()
        timer = nil
        player.stop()
        engine.stop()
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
            stopPlayback(publishStatus: false)
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
        return stringProperty(kAudioObjectPropertyName, for: deviceID)
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
