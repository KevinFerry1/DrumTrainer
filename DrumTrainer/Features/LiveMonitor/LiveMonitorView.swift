import SwiftUI

struct LiveMonitorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            deviceControls
            metronomeControls
            levelMonitor
            eventLog
            diagnostics
        }
        .padding(20)
        .navigationTitle("Live Timing Foundation")
        .task { state.startHardwareMonitoring() }
    }

    private var deviceControls: some View {
        GroupBox("Hardware inputs") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("MIDI")
                        .frame(width: 78, alignment: .leading)
                    Picker("MIDI input", selection: Binding(
                        get: { state.selectedMIDIInputID },
                        set: { state.selectMIDIInput($0) }
                    )) {
                        Text("None").tag(Optional<Int32>.none)
                        ForEach(state.midiDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Text(state.midiStatus.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Pad map")
                        .frame(width: 78, alignment: .leading)
                    if state.selectedMIDIInputID == nil {
                        Text("Select your drum module to edit its saved note map.")
                            .foregroundStyle(.secondary)
                    } else if let note = state.lastMIDINote {
                        Text("Last note \(note) · velocity \(state.lastMIDIVelocity ?? 0)")
                            .monospacedDigit()
                        Picker("Voice", selection: $state.midiMappingVoice) {
                            ForEach(DrumVoice.allCases.filter { $0 != .metronome }, id: \.rawValue) { voice in
                                Text(voice.displayName).tag(voice)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 190)
                        Button("Save for This Device") { state.saveMappingForLastMIDINote() }
                        Button("Use General MIDI Default") { state.resetMappingForLastMIDINote() }
                    } else {
                        Text("Strike a pad, then choose its correct voice.")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Microphone")
                        .frame(width: 78, alignment: .leading)
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
                    .frame(maxWidth: 300)
                    if state.microphonePermission == .notDetermined {
                        Button("Grant Access") { state.requestMicrophoneAccess() }
                    } else if state.microphonePermission == .denied {
                        Button("Open Settings") { state.openMicrophonePrivacySettings() }
                    }
                    Text(state.audioStatus.message)
                        .font(.callout)
                        .foregroundStyle(state.audioStatus == .permissionDenied ? Color.orange : Color.secondary)
                    Spacer()
                }
            }
        }
    }

    private var metronomeControls: some View {
        GroupBox("Metronome") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Output")
                        .frame(width: 78, alignment: .leading)
                    Picker("Audio output", selection: Binding(
                        get: { state.selectedAudioOutputID },
                        set: { state.selectAudioOutput($0) }
                    )) {
                        Text("System Default").tag(Optional<UInt32>.none)
                        ForEach(state.audioOutputDevices) { device in
                            Text(device.name).tag(Optional(device.id))
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 300)
                    Text(state.metronomeStatus.message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Tempo")
                        .frame(width: 78, alignment: .leading)
                    Text("\(Int(state.metronomeBPM)) BPM")
                        .frame(width: 74, alignment: .trailing)
                        .monospacedDigit()
                    Slider(value: $state.metronomeBPM, in: 40...240, step: 1)
                        .frame(maxWidth: 260)
                    Stepper("", value: $state.metronomeBPM, in: 40...240, step: 1)
                        .labelsHidden()
                    Button(state.isMetronomeRunning ? "Stop Metronome" : "Start Metronome") {
                        state.toggleMetronome()
                    }
                    .keyboardShortcut(.return, modifiers: [])
                    Spacer()
                }
                .font(.callout)

                HStack(spacing: 12) {
                    Text("Click")
                        .frame(width: 78, alignment: .leading)
                    Picker("Click sound", selection: $state.metronomeSound) {
                        ForEach(MetronomeSound.allCases) { sound in
                            Text(sound.displayName).tag(sound)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
                    Text(state.metronomeSound.guidance)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                HStack(spacing: 12) {
                    Text("Level")
                        .frame(width: 78, alignment: .leading)
                    Text(state.metronomeGainDecibels.formatted(.number.sign(strategy: .always()).precision(.fractionLength(0))) + " dB")
                        .frame(width: 58, alignment: .trailing)
                        .monospacedDigit()
                    Slider(value: $state.metronomeGainDecibels, in: -36...12, step: 1)
                        .frame(maxWidth: 220)
                    Toggle("Limiter", isOn: $state.metronomeLimiterEnabled)
                        .toggleStyle(.switch)
                    Text("Ceiling")
                    Slider(value: $state.metronomeLimiterCeilingDBFS, in: -12 ... -0.5, step: 0.5)
                        .frame(width: 100)
                        .disabled(!state.metronomeLimiterEnabled)
                    Text("\(state.metronomeLimiterCeilingDBFS, specifier: "%.1f") dBFS")
                        .monospacedDigit()
                    Spacer()
                }
                .font(.callout)

                AppOutputMeterView(level: state.appOutputLevel)
            }
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Drum Performance Trainer")
                    .font(.title.bold())
                Text("Common host-time event monitor")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(state.isSimulationRunning ? "Stop Test Simulation" : "Start Test Simulation") {
                state.toggleSimulation()
            }
            Button("Clear") { state.clearEvents() }
                .disabled(state.events.isEmpty)
        }
    }

    private var levelMonitor: some View {
        GroupBox("Kick microphone") {
            VStack(spacing: 10) {
                Canvas { context, size in
                    guard state.recentLevels.count > 1 else { return }
                    var path = Path()
                    for (index, level) in state.recentLevels.enumerated() {
                        let x = size.width * Double(index) / Double(state.recentLevels.count - 1)
                        let y = size.height * (1 - level)
                        index == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                    context.stroke(path, with: .color(.cyan), lineWidth: 2)
                }
                .frame(height: 70)
                .accessibilityLabel("Microphone envelope level")

                HStack(spacing: 16) {
                    Text("Threshold \(state.kickThreshold.formatted(.number.precision(.fractionLength(2))))")
                    Slider(value: $state.kickThreshold, in: 0.05...0.95, step: 0.01)
                        .frame(maxWidth: 260)
                    Text("Lockout \(Int(state.retriggerLockoutMilliseconds)) ms")
                    Slider(value: $state.retriggerLockoutMilliseconds, in: 15...100, step: 1)
                        .frame(maxWidth: 220)
                    Spacer()
                }
                .font(.callout.monospacedDigit())

                HStack(spacing: 12) {
                    Toggle("Kick sound filter", isOn: $state.kickSoundFilterEnabled)
                        .toggleStyle(.switch)
                        .disabled(state.activeMicrophoneCalibrationProfile?.kickSoundSignature == nil)
                    if state.activeMicrophoneCalibrationProfile?.kickSoundSignature == nil {
                        Text("Recalibrate once to teach the app your kick pad's sound.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    } else {
                        Text("Match \(state.minimumKickSoundSimilarity.formatted(.percent.precision(.fractionLength(0))))")
                            .monospacedDigit()
                        Slider(value: $state.minimumKickSoundSimilarity, in: 0.05...0.75, step: 0.05)
                            .frame(maxWidth: 180)
                        if let similarity = state.lastKickSoundSimilarity {
                            Text("Last \(similarity.formatted(.percent.precision(.fractionLength(0))))")
                                .monospacedDigit()
                                .foregroundStyle(similarity >= state.minimumKickSoundSimilarity ? Color.green : Color.orange)
                        }
                        if state.rejectedNonKickSoundCount > 0 {
                            Label("Sound filtered \(state.rejectedNonKickSoundCount)", systemImage: "waveform.badge.minus")
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                }
                .font(.callout)

                HStack(spacing: 12) {
                    Toggle("E-kit crosstalk guard", isOn: $state.midiCrosstalkSuppressionEnabled)
                        .toggleStyle(.switch)
                    Text("Uses MIDI coincidence as a fallback; a transient matching your calibrated kick sound always passes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if state.suppressedMicrophoneCrosstalkCount > 0 {
                        Label(
                            "Filtered \(state.suppressedMicrophoneCrosstalkCount)",
                            systemImage: "waveform.badge.minus"
                        )
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.orange)
                    }
                    Spacer()
                }
            }
        }
    }

    private var eventLog: some View {
        GroupBox("Unified event log") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Picker("Timestamp", selection: $state.eventTimestampDisplayMode) {
                        ForEach(EventTimestampDisplayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 280)
                    Text("Source/detection correction: uncalibrated (0 ms)")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Spacer()
                }

                Table(Array(state.events.reversed())) {
                    TableColumn(state.eventTimestampDisplayMode.columnTitle) { event in
                        Text(event.formattedTimestamp(state.eventTimestampDisplayMode)).monospacedDigit()
                    }
                    .width(min: 120, ideal: 155)
                    TableColumn("Source") { event in Text(event.source.displayName) }
                        .width(min: 90, ideal: 110)
                    TableColumn("Voice") { event in Text(event.voice.displayName) }
                        .width(min: 100, ideal: 130)
                    TableColumn("Confidence") { event in
                        Text(event.confidence.formatted(.percent.precision(.fractionLength(0))))
                    }
                    .width(min: 80, ideal: 90)
                    TableColumn("Raw metadata") { event in Text(event.rawMetadata.diagnosticSummary) }
                }
                .frame(minHeight: 280)
            }
        }
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Events: \(state.events.count) / 500", systemImage: "waveform.path.ecg")
                Label("Crosstalk filtered: \(state.suppressedMicrophoneCrosstalkCount)", systemImage: "waveform.badge.minus")
                    .foregroundStyle(state.suppressedMicrophoneCrosstalkCount == 0 ? Color.secondary : Color.orange)
                Label("Other sounds filtered: \(state.rejectedNonKickSoundCount)", systemImage: "waveform.badge.minus")
                    .foregroundStyle(state.rejectedNonKickSoundCount == 0 ? Color.secondary : Color.orange)
                Spacer()
                Label("Dropped: \(state.droppedEventCount)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(state.droppedEventCount == 0 ? Color.secondary : Color.orange)
            }
            HStack {
                Text("Session origin: \(state.sessionOriginHostTime.formatted(.number.grouping(.never))) host ticks")
                Spacer()
                metronomeHealthLabel
            }
        }
        .font(.callout.monospacedDigit())
        .foregroundStyle(.secondary)
    }

    private var metronomeHealthLabel: some View {
        let health = state.metronomeSchedulingHealth
        let minimumLead = health.minimumLeadTimeMilliseconds.map {
            $0.formatted(.number.precision(.fractionLength(1))) + " ms min lead"
        } ?? "waiting for ticks"
        return Label(
            "Metronome: \(minimumLead) · \(health.atRiskTickCount) at risk / \(health.scheduledTickCount)",
            systemImage: health.hasWarning ? "exclamationmark.triangle.fill" : "checkmark.circle"
        )
        .foregroundStyle(health.hasWarning ? Color.orange : Color.secondary)
        .help("A tick is at risk when it reaches the audio scheduler with less than 20 ms of lead time.")
    }
}

struct AppOutputMeterView: View {
    let level: AppOutputLevel

    var body: some View {
        HStack(spacing: 10) {
            Text("App output")
                .frame(width: 78, alignment: .leading)
            GeometryReader { geometry in
                let fraction = min(max((level.peakDBFS + 60) / 60, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(meterColor)
                        .frame(width: geometry.size.width * fraction)
                }
            }
            .frame(width: 220, height: 10)
            Text("peak \(format(level.peakDBFS)) · RMS \(format(level.rmsDBFS))")
                .monospacedDigit()
                .frame(width: 190, alignment: .leading)
            if level.limiterReductionDB > 0.05 {
                Text("limiting −\(level.limiterReductionDB, specifier: "%.1f") dB")
                    .foregroundStyle(.orange)
                    .monospacedDigit()
            }
            Spacer()
            Text("Digital dBFS · app audio only, not headphone SPL")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .help("This meter covers audio generated by DrumTrainer. Real headphone dB SPL requires calibration for the interface, headphones, and physical volume setting.")
    }

    private var meterColor: Color {
        if level.peakDBFS >= -1 { return .red }
        if level.peakDBFS >= -6 { return .orange }
        return .green
    }

    private func format(_ value: Double) -> String {
        value <= -79.9 ? "−∞" : value.formatted(.number.precision(.fractionLength(1))) + " dBFS"
    }
}
