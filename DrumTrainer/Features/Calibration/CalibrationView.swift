import SwiftUI

struct CalibrationView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                microphoneSelector
                signalMonitor
                calibrationWorkflow
                timingAlignmentWorkflow
            }
            .padding(20)
        }
        .navigationTitle("Calibration")
        .task { state.startHardwareMonitoring() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Input & Timing Calibration")
                .font(.title.bold())
            Text("Tune kick detection, then align MIDI or microphone hits to the click you actually hear")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var timingAlignmentWorkflow: some View {
        GroupBox("Hit timing alignment") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Measures the complete path between the audible click and a raw hit: the selected headphone output, your typical response, and the chosen input. The saved correction is scoped to that exact input/output pairing.")
                    .font(.callout)
                    .foregroundStyle(.secondary)

                HStack(spacing: 16) {
                    Picker("Input path", selection: $state.timingAlignmentSource) {
                        ForEach(TimingAlignmentSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .frame(width: 230)
                    .disabled(state.timingAlignmentPhase.isActive)

                    if state.timingAlignmentSource == .midi {
                        Picker("Drum to play", selection: $state.timingAlignmentVoice) {
                            ForEach(
                                DrumVoice.allCases.filter { $0 != .metronome && $0 != .unknown },
                                id: \.self
                            ) { voice in
                                Text(voice.displayName).tag(voice)
                            }
                        }
                        .frame(width: 220)
                        .disabled(state.timingAlignmentPhase.isActive)
                    } else {
                        Label("Play kick", systemImage: "circle.inset.filled")
                    }
                    Spacer()
                }

                HStack(spacing: 20) {
                    Label("Output: \(selectedOutputName)", systemImage: "headphones")
                    if let latency = state.metronomeOutputPresentationLatencyMilliseconds {
                        Label(
                            "Reported downstream latency \(latency.formatted(.number.precision(.fractionLength(1)))) ms",
                            systemImage: "waveform.path.ecg"
                        )
                    }
                    Button(state.isRefreshingAudioEngine ? "Refreshing…" : "Refresh Audio") {
                        state.refreshAudioEngine()
                    }
                    .disabled(state.isRefreshingAudioEngine)
                    Spacer()
                }
                .font(.callout.monospacedDigit())

                if let message = state.audioEngineRecoveryMessage {
                    Label(message, systemImage: "arrow.clockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                switch state.timingAlignmentPhase {
                case .idle:
                    if let profile = state.activeTimingAlignmentProfile {
                        timingProfileSummary(profile)
                        HStack {
                            Button("Re-align") { state.startTimingAlignment() }
                            Button("Delete Saved Alignment", role: .destructive) {
                                state.deleteActiveTimingAlignment()
                            }
                        }
                    } else {
                        instruction(
                            "Ready for 12 clicks at 60 BPM",
                            detail: "After an eight-beat, two-bar count-in, play the selected drum exactly once on every click. Use the headphones and posture you normally practice with.",
                            icon: "metronome"
                        )
                        Button("Start Timing Alignment") { state.startTimingAlignment() }
                            .disabled(state.isRefreshingAudioEngine)
                    }

                case .starting:
                    HStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.small)
                        instruction(
                            "Starting audible click",
                            detail: "Opening \(selectedOutputName) and confirming the output timeline.",
                            icon: "headphones"
                        )
                        Spacer()
                        Button("Refresh Audio & Retry") { state.refreshAudioEngineAndRetryTimingAlignment() }
                            .disabled(state.isRefreshingAudioEngine)
                        Button("Cancel") { state.cancelTimingAlignment() }
                    }

                case let .countIn(beatsRemaining):
                    HStack(spacing: 20) {
                        Text("\(beatsRemaining)")
                            .font(.system(size: 46, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 56)
                        instruction(
                            "Count in",
                            detail: "Listen only. Start playing after the countdown.",
                            icon: "ear"
                        )
                        Spacer()
                        Button("Cancel") { state.cancelTimingAlignment() }
                    }

                case let .collecting(referenceCount, target, detectedHits):
                    instruction(
                        "Play once on every click",
                        detail: "Click \(referenceCount) of \(target) · detected \(detectedHits) matching \(state.timingAlignmentSource == .midi ? state.timingAlignmentVoice.displayName : "kick") hits.",
                        icon: "waveform.and.mic"
                    )
                    ProgressView(value: Double(referenceCount), total: Double(target))
                    HStack {
                        Text("\(referenceCount) / \(target)")
                            .font(.headline.monospacedDigit())
                        Spacer()
                        Button("Refresh Audio & Retry") { state.refreshAudioEngineAndRetryTimingAlignment() }
                            .disabled(state.isRefreshingAudioEngine)
                        Button("Cancel") { state.cancelTimingAlignment() }
                    }

                case let .review(profile):
                    timingProfileSummary(profile)
                    Text("Positive compensation means the raw input arrived after the audible click; scoring will move that input earlier by the shown amount. Raw recorded timestamps are never changed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Save & Apply") { state.saveTimingAlignment() }
                            .keyboardShortcut(.return, modifiers: [])
                        Button("Retry") { state.startTimingAlignment() }
                        Button("Cancel") { state.cancelTimingAlignment() }
                    }

                case let .saved(profile):
                    timingProfileSummary(profile)
                    Label("Timing correction saved and applied to new practice scores.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Done") { state.dismissTimingAlignmentStatus() }

                case let .error(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Retry") { state.startTimingAlignment() }
                        Button("Refresh Audio & Retry") { state.refreshAudioEngineAndRetryTimingAlignment() }
                            .disabled(state.isRefreshingAudioEngine)
                        Button("Dismiss") { state.dismissTimingAlignmentStatus() }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var selectedOutputName: String {
        guard let id = state.selectedAudioOutputID else { return "System Default" }
        return state.audioOutputDevices.first(where: { $0.id == id })?.name ?? "Selected output"
    }

    private func timingProfileSummary(_ profile: TimingAlignmentProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 26) {
                metric(
                    "Applied correction",
                    profile.compensationMilliseconds.formatted(.number.precision(.fractionLength(1))) + " ms"
                )
                metric(
                    "Hit variability",
                    profile.medianAbsoluteDeviationMilliseconds.formatted(.number.precision(.fractionLength(1))) + " ms"
                )
                metric("Usable samples", "\(profile.sampleCount)")
                Spacer()
            }
            Text("\(profile.inputName) → \(profile.outputName) · \(profile.voice.displayName) · saved \(profile.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if profile.medianAbsoluteDeviationMilliseconds > 30 {
                Text("Hit variability is high. Retry at a comfortable posture and concentrate on landing naturally with the click.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var microphoneSelector: some View {
        GroupBox("Microphone") {
            HStack(spacing: 12) {
                Picker("Audio input", selection: Binding(
                    get: { state.selectedAudioInputID },
                    set: { state.selectAudioInput($0) }
                )) {
                    Text("None").tag(Optional<UInt32>.none)
                    ForEach(state.audioDevices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)
                .disabled(state.microphoneCalibrationPhase.isActive)

                if state.microphonePermission == .notDetermined {
                    Button("Grant Access") { state.requestMicrophoneAccess() }
                } else if state.microphonePermission == .denied {
                    Button("Open Privacy Settings") { state.openMicrophonePrivacySettings() }
                }

                Text(state.audioStatus.message)
                    .font(.callout)
                    .foregroundStyle(state.microphonePermission == .denied ? Color.orange : Color.secondary)
                if state.selectedAudioInputID != nil,
                   !state.audioStatus.isMonitoring {
                    Button(state.audioStatus.isStarting ? "Restart Monitoring" : "Start Monitoring") {
                        state.restartSelectedAudioInputMonitoring()
                    }
                    .buttonStyle(.borderedProminent)
                }
                Spacer()
            }
        }
    }

    private var signalMonitor: some View {
        GroupBox("Live signal") {
            VStack(alignment: .leading, spacing: 10) {
                Canvas { context, size in
                    guard state.recentLevels.count > 1 else { return }
                    var path = Path()
                    for (index, level) in state.recentLevels.enumerated() {
                        let x = size.width * Double(index) / Double(state.recentLevels.count - 1)
                        let y = size.height * (1 - level)
                        index == 0
                            ? path.move(to: CGPoint(x: x, y: y))
                            : path.addLine(to: CGPoint(x: x, y: y))
                    }
                    context.stroke(path, with: .color(.cyan), lineWidth: 2)

                    let thresholdY = size.height * (1 - state.kickThreshold)
                    var thresholdPath = Path()
                    thresholdPath.move(to: CGPoint(x: 0, y: thresholdY))
                    thresholdPath.addLine(to: CGPoint(x: size.width, y: thresholdY))
                    context.stroke(thresholdPath, with: .color(.orange), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))

                    if let noise = state.calibrationNoiseEstimate {
                        let noiseY = size.height * (1 - noise.percentile95Level)
                        var noisePath = Path()
                        noisePath.move(to: CGPoint(x: 0, y: noiseY))
                        noisePath.addLine(to: CGPoint(x: size.width, y: noiseY))
                        context.stroke(noisePath, with: .color(.purple), lineWidth: 1)
                    }
                }
                .frame(height: 110)
                .accessibilityLabel("Microphone level with threshold and calibrated noise floor")

                HStack(spacing: 20) {
                    Label("Threshold \(number(state.kickThreshold))", systemImage: "line.3.horizontal.decrease")
                        .foregroundStyle(.orange)
                    if let noise = state.calibrationNoiseEstimate {
                        Label("Noise p95 \(number(noise.percentile95Level))", systemImage: "waveform")
                            .foregroundStyle(.purple)
                    }
                    Label("Lockout \(Int(state.retriggerLockoutMilliseconds)) ms", systemImage: "timer")
                    Spacer()
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    @ViewBuilder
    private var calibrationWorkflow: some View {
        GroupBox("Guided calibration") {
            VStack(alignment: .leading, spacing: 14) {
                switch state.microphoneCalibrationPhase {
                case .idle:
                    if let profile = state.activeMicrophoneCalibrationProfile {
                        profileSummary(profile, saved: true)
                        HStack {
                            Button("Recalibrate") { state.startMicrophoneCalibration() }
                            Button("Delete Saved Profile", role: .destructive) {
                                state.deleteActiveMicrophoneCalibration()
                            }
                        }
                    } else {
                        instruction(
                            "Ready to calibrate",
                            detail: "Keep the room quiet for three seconds, then play 20 isolated kick strikes. This learns both their level and distinctive sound.",
                            icon: "mic.badge.plus"
                        )
                        Button("Start Calibration") { state.startMicrophoneCalibration() }
                            .disabled(state.selectedAudioInputID == nil)
                    }

                case .preparingInput:
                    HStack(spacing: 14) {
                        ProgressView()
                            .controlSize(.small)
                        instruction(
                            "Starting microphone",
                            detail: "Waiting for live samples from the selected input before the quiet-room timer begins.",
                            icon: "waveform"
                        )
                        Spacer()
                        Button("Cancel") { state.cancelMicrophoneCalibration() }
                    }

                case let .samplingNoise(secondsRemaining):
                    HStack(spacing: 18) {
                        Text("\(secondsRemaining)")
                            .font(.system(size: 42, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .frame(width: 54)
                        instruction(
                            "Sampling room noise",
                            detail: "Stay quiet and do not strike the pad.",
                            icon: "ear"
                        )
                        Spacer()
                        Button("Cancel") { state.cancelMicrophoneCalibration() }
                    }

                case let .collectingHits(detected, target):
                    instruction(
                        detected < target / 2 ? "Play isolated kick strikes" : "Add simultaneous e-kit hits",
                        detail: detected < target / 2
                            ? "Detected \(detected) of \(target). Vary the strength and use both beaters."
                            : "Detected \(detected) of \(target). Keep kicking, but play snare, tom, or cymbal at the same instant so real combined hits are learned.",
                        icon: "figure.indoor.cycle"
                    )
                    ProgressView(value: Double(detected), total: Double(target))
                    HStack {
                        Text("\(detected) / \(target)")
                            .font(.headline.monospacedDigit())
                        if state.calibrationSuppressedTransientCount > 0 {
                            Label(
                                "Ignored \(state.calibrationSuppressedTransientCount) likely secondary transient\(state.calibrationSuppressedTransientCount == 1 ? "" : "s")",
                                systemImage: "waveform.badge.minus"
                            )
                            .font(.callout)
                            .foregroundStyle(.orange)
                        }
                        Spacer()
                        Button("Cancel") { state.cancelMicrophoneCalibration() }
                    }

                case let .review(profile):
                    profileSummary(profile, saved: false)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Threshold \(number(state.kickThreshold))")
                                .frame(width: 122, alignment: .leading)
                            Slider(value: $state.kickThreshold, in: 0.03...0.95, step: 0.01)
                                .frame(maxWidth: 320)
                        }
                        HStack {
                            Text("Lockout \(Int(state.retriggerLockoutMilliseconds)) ms")
                                .frame(width: 122, alignment: .leading)
                            Slider(value: $state.retriggerLockoutMilliseconds, in: 15...100, step: 1)
                                .frame(maxWidth: 320)
                        }
                    }
                    .font(.callout.monospacedDigit())
                    HStack {
                        Button("Save Profile") { state.saveMicrophoneCalibration() }
                            .keyboardShortcut(.return, modifiers: [])
                        Button("Retry") {
                            state.cancelMicrophoneCalibration()
                            state.startMicrophoneCalibration()
                        }
                        Button("Cancel") { state.cancelMicrophoneCalibration() }
                    }

                case let .saved(profile):
                    profileSummary(profile, saved: true)
                    Label("Calibration saved and applied to this microphone.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Button("Done") { state.dismissMicrophoneCalibrationStatus() }

                case let .error(message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    HStack {
                        Button("Retry") {
                            state.cancelMicrophoneCalibration()
                            state.startMicrophoneCalibration()
                        }
                        Button("Dismiss") { state.dismissMicrophoneCalibrationStatus() }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func instruction(_ title: String, detail: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private func profileSummary(_ profile: MicrophoneCalibrationProfile, saved: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(
                    profile.quality.displayName,
                    systemImage: profile.quality == .good ? "checkmark.seal.fill" : "exclamationmark.triangle.fill"
                )
                .font(.headline)
                .foregroundStyle(qualityColor(profile.quality))
                Spacer()
                if saved {
                    Text("Saved \(profile.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 26) {
                metric("Noise floor", number(profile.noiseFloor))
                metric("Weakest hit", number(profile.weakestHitAmplitude))
                metric("Median hit", number(profile.medianHitAmplitude))
                metric("Separation", profile.signalToNoiseDecibels.formatted(.number.precision(.fractionLength(1))) + " dB")
                metric("Detected", "\(profile.detectedHitCount) hits")
                metric("Sound filter", profile.kickSoundSignature == nil ? "Not learned" : "Learned")
                Spacer()
            }
            if profile.kickSoundSignature == nil, saved {
                Text("This older profile has no kick sound model. Recalibrate once to reject speech, stick clicks, cymbals, and pad bleed by sound.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if profile.quality == .poor {
                Text("Signal separation is poor. Move the microphone closer to the pad, reduce monitor bleed, and retry before trusting timing results.")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func qualityColor(_ quality: CalibrationQuality) -> Color {
        switch quality {
        case .good: .green
        case .marginal: .orange
        case .poor: .red
        }
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(3)))
    }
}
