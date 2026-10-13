import SwiftUI

struct PianoDeviceControls: View {
    @ObservedObject var state: AppState
    @ObservedObject var piano: PianoPracticeController

    init(state: AppState) { self.state = state; self.piano = state.piano }

    var body: some View {
        GroupBox("Piano connection") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("MIDI input", selection: Binding(get: { state.selectedMIDIInputID }, set: { state.selectMIDIInput($0) })) {
                        Text("None").tag(Optional<Int32>.none)
                        ForEach(state.midiDevices) { Text($0.name).tag(Optional($0.id)) }
                        if let id = state.selectedMIDIInputID, !state.midiDevices.contains(where: { $0.id == id }) {
                            Text("Saved input (disconnected)").tag(Optional(id))
                        }
                    }
                    Button("Rescan") { state.refreshMIDIInputs() }
                    Picker("Channel", selection: Binding(get: { state.pianoPreferences.channel }, set: { value in
                        state.updatePianoPreferences { $0.channel = value }
                    })) {
                        Text("All").tag(Optional<UInt8>.none)
                        ForEach(1...16, id: \.self) { Text("\($0)").tag(Optional(UInt8($0))) }
                    }.frame(maxWidth: 160)
                }
                Picker("Click output", selection: Binding(get: { state.selectedAudioOutputID }, set: { state.selectAudioOutput($0) })) {
                    Text("System Default").tag(Optional<UInt32>.none)
                    ForEach(state.audioOutputDevices) { Text($0.name).tag(Optional($0.id)) }
                }
                Text(state.midiStatus.message).font(.callout).foregroundStyle(.secondary)
                Text("Use your piano or an existing instrument app for sound. MIDI is used for grading; DrumTrainer plays the click.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
        .disabled(piano.phase.isActive || state.timingAlignmentPhase.locksConfiguration)
    }
}

struct PianoLiveMonitorView: View {
    @ObservedObject var state: AppState
    @ObservedObject var piano: PianoPracticeController
    init(state: AppState) { self.state = state; self.piano = state.piano }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Electric Piano").font(.largeTitle.bold())
                Text("Play a key to see its pitch, velocity, release, and sustain state.").foregroundStyle(.secondary)
                PianoDeviceControls(state: state)
                PianoKeyboardView(held: piano.input.heldPitches, sounding: piano.input.soundingPitches)
                HStack {
                    Label(piano.input.sustainChannels.isEmpty ? "Sustain off" : "Sustain on", systemImage: "pianokeys")
                    Text("Held: " + piano.input.heldPitches.sorted { $0.noteNumber < $1.noteNumber }.map(\.displayName).joined(separator: ", "))
                    Spacer()
                    Button("Reset keys") { piano.resetKeys() }
                }
                if piano.input.droppedCount > 0 || piano.input.issueCount > 0 {
                    Text("Some input was lost or ambiguous. Reset keys before the next exercise.").foregroundStyle(.orange)
                }
                GroupBox("Recent notes") {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if piano.input.orderedNotes.isEmpty { Text("Waiting for MIDI notes…").foregroundStyle(.secondary) }
                        ForEach(Array(piano.input.orderedNotes.suffix(40).reversed())) { note in
                            HStack {
                                Text(note.pitch.displayName).fontWeight(.semibold).frame(width: 60, alignment: .leading)
                                Text("Velocity \(note.velocity)").frame(width: 110, alignment: .leading)
                                Text("Channel \(note.input.channel)").frame(width: 100, alignment: .leading)
                                Text(note.isInterrupted ? "Interrupted" : (note.isKeyDown ? "Key down" : (note.isSounding ? "Pedal sustained" : "Released")))
                                    .foregroundStyle(note.isUncertain || note.isInterrupted ? .orange : .secondary)
                                Spacer()
                            }.font(.callout.monospacedDigit())
                        }
                    }.padding(8)
                }
            }.padding(24)
        }.task { state.startHardwareMonitoring() }
    }
}

struct PianoPracticeView: View {
    @ObservedObject var state: AppState
    @ObservedObject var piano: PianoPracticeController
    init(state: AppState) { self.state = state; self.piano = state.piano }

    private var preview: PianoPracticePattern {
        piano.pattern ?? .make(exercise: state.pianoPreferences.exercise, bpm: state.practiceBPM, repeats: state.pianoPreferences.repeats)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Piano Practice").font(.largeTitle.bold())
                DisclosureGroup("Piano connection") { PianoDeviceControls(state: state) }
                GroupBox("Exercise") {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Exercise", selection: Binding(get: { state.pianoPreferences.exercise }, set: { value in
                            state.updatePianoPreferences { $0.exercise = value }
                        })) { ForEach(PianoExercise.allCases) { Text($0.displayName).tag($0) } }
                        Text(state.pianoPreferences.exercise.guide).foregroundStyle(.secondary)
                        HStack {
                            Stepper("\(Int(state.practiceBPM)) BPM", value: $state.practiceBPM, in: 40...240, step: 1)
                            Stepper("\(state.pianoPreferences.repeats) repeats", value: Binding(get: { state.pianoPreferences.repeats }, set: { value in
                                state.updatePianoPreferences { $0.repeats = value }
                            }), in: 1...16)
                        }
                        Toggle("Grade key-release duration", isOn: Binding(get: { state.pianoPreferences.gradeDuration }, set: { value in
                            state.updatePianoPreferences { $0.gradeDuration = value }
                        }))
                        Text("Bars show the target hold time, with a short gap before the next attack. Duration uses key release, even when the pedal keeps the sound ringing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }.disabled(piano.phase.isActive)

                status
                HStack {
                    Button(piano.outcome == nil ? "Start Exercise" : "Play Again") { state.startPianoPractice() }
                        .buttonStyle(.borderedProminent)
                        .disabled(piano.phase.isActive || state.timingAlignmentPhase.locksConfiguration || state.isRefreshingAudioEngine)
                    if piano.phase.isActive { Button("Cancel") { piano.cancel(clearInput: false) } }
                    Button("Reset Practice") { state.resetPracticeTransport() }
                    Text("Eight count-in clicks, then begin.").foregroundStyle(.secondary)
                }
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !piano.phase.isActive)) { _ in
                    PianoRollView(pattern: preview, playheadNanoseconds: piano.playheadNanoseconds,
                                  results: piano.outcome?.results ?? [], gradeDuration: state.pianoPreferences.gradeDuration)
                }
                PianoKeyboardView(held: piano.input.heldPitches, sounding: piano.input.soundingPitches)
                if let outcome = piano.outcome { PianoResultsView(outcome: outcome) }
                Text("Piano history, custom exercises, song imports, recordings, and automatic tempo progression come in the next phase. These results stay here until the next attempt or instrument switch.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }.task { state.startHardwareMonitoring() }
    }

    @ViewBuilder private var status: some View {
        switch piano.phase {
        case .idle: Text("Ready").font(.headline)
        case let .countIn(remaining): Text(remaining > 0 ? "Count-in: \(remaining) clicks remaining" : "Get ready…").font(.headline).foregroundStyle(.blue)
        case .running: Text("Playing — follow the blue line").font(.headline).foregroundStyle(.blue)
        case .results: Text("Results").font(.headline)
        case let .error(message): Text(message).foregroundStyle(.orange)
        }
    }
}

struct PianoResultsView: View {
    let outcome: PianoPracticeOutcome
    private var summary: some View {
        HStack(spacing: 28) {
            Text("Pitch accuracy: \(outcome.recall.formatted(.percent.precision(.fractionLength(1))))")
            Text("Correct: \(outcome.correctCount)/\(outcome.pattern.notes.count)")
            Text("Extra: \(outcome.extraCount)")
            Text("Median timing error: " + (outcome.medianAbsoluteOnsetErrorMilliseconds.map { $0.formatted(.number.precision(.fractionLength(1))) + " ms" } ?? "—"))
        }.font(.callout.bold()).monospacedDigit()
    }
    var body: some View {
        GroupBox("Performance results") {
            VStack(alignment: .leading, spacing: 14) {
                summary
                if !outcome.isVerified {
                    Text("Unverified input: \(outcome.droppedCount) dropped events, \(outcome.inputIssueCount) input issues. Interrupted or bent notes cannot earn pitch credit.")
                        .foregroundStyle(.orange)
                }
                if !outcome.chords.isEmpty {
                    Text("Chords together: \(outcome.chords.filter(\.passes).count)/\(outcome.chords.count). Target spread: 80 ms or less, with every tone present and no extra tone.")
                }
                if outcome.configuration.gradeDuration {
                    Text("Key-release duration: \(outcome.results.filter { $0.classification == .correct && $0.durationPassed == true }.count)/\(outcome.pattern.notes.count) within 150 ms. Missing releases are unavailable.")
                }
                Text("Negative timing = early; positive timing = late. Pitch uses the exact octave.").font(.caption).foregroundStyle(.secondary)
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(outcome.results.prefix(200))) { result in
                        PianoResultRow(result: result, gradeDuration: outcome.configuration.gradeDuration)
                    }
                    if outcome.results.count > 200 {
                        Text("Showing the first 200 of \(outcome.results.count) note results.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.padding(8)
        }
    }
}

private struct PianoResultRow: View {
    let result: PianoNoteResult
    let gradeDuration: Bool
    var body: some View {
        HStack {
            Text(result.expectedPitch?.displayName ?? "—").frame(width: 65, alignment: .leading)
            Image(systemName: "arrow.right")
            Text(result.actualPitch?.displayName ?? "—").frame(width: 65, alignment: .leading)
            Text(result.classification == .wrongPitch ? "Wrong pitch" : result.classification.rawValue.capitalized)
                .frame(width: 110, alignment: .leading)
            Text(result.onsetErrorMilliseconds.map { String(format: "%+.1f ms", $0) } ?? "—")
                .frame(width: 100, alignment: .trailing)
            if gradeDuration {
                Text(result.durationErrorMilliseconds.map { String(format: "Hold %+.1f ms", $0) } ?? "Hold unavailable")
                    .foregroundStyle(result.durationPassed == true ? Color.secondary : Color.orange)
            }
            Spacer()
        }.font(.callout.monospacedDigit())
    }
}

struct PianoKeyboardView: View {
    let held: Set<MIDIPitch>
    let sounding: Set<MIDIPitch>
    private let range = Array(48...84)
    private func isBlack(_ pitch: Int) -> Bool { [1,3,6,8,10].contains(pitch % 12) }

    var body: some View {
        Canvas { context, size in
            let whites = range.filter { !isBlack($0) }
            let width = size.width / Double(whites.count)
            for (index, value) in whites.enumerated() {
                let pitch = MIDIPitch(value)!
                let rect = CGRect(x: Double(index) * width, y: 0, width: width - 1, height: size.height)
                let color: Color = held.contains(pitch) ? .blue : (sounding.contains(pitch) ? .green.opacity(0.65) : .white)
                context.fill(Path(rect), with: .color(color))
                context.stroke(Path(rect), with: .color(.gray.opacity(0.6)), lineWidth: 1)
                if value % 12 == 0 {
                    context.draw(Text(pitch.displayName).font(.caption2).foregroundStyle(.black), at: CGPoint(x: rect.midX, y: rect.maxY - 12))
                }
            }
            for value in range where isBlack(value) {
                let pitch = MIDIPitch(value)!
                let left = whites.filter { $0 < value }.count
                let rect = CGRect(x: Double(left) * width - width * 0.3, y: 0, width: width * 0.6, height: size.height * 0.62)
                context.fill(Path(rect), with: .color(held.contains(pitch) ? .blue : (sounding.contains(pitch) ? .green : .black)))
            }
        }
        .frame(height: 110)
        .accessibilityLabel("Piano keyboard, C3 to C6")
        .accessibilityValue("Held keys: " + held.sorted { $0.noteNumber < $1.noteNumber }.map(\.displayName).joined(separator: ", "))
    }
}

struct PianoRollView: View {
    let pattern: PianoPracticePattern
    var playheadNanoseconds: Int64?
    var results: [PianoNoteResult] = []
    var gradeDuration = false

    var body: some View {
        Canvas { context, size in
            let viewWidth = Double(size.width), viewHeight = Double(size.height)
            let low = max(Int(pattern.notes.map { $0.pitch.noteNumber }.min() ?? 60) - 1, 0)
            let high = min(Int(pattern.notes.map { $0.pitch.noteNumber }.max() ?? 72) + 1, 127)
            let rowHeight = viewHeight / Double(high - low + 1)
            let beat = 60_000_000_000 / pattern.bpm
            let scale = 62.0 / beat
            let playhead = Double(max(playheadNanoseconds ?? 0, 0)) * scale
            let offset = max(playhead - (viewWidth - 64) * 0.35, 0)
            for pitch in low...high {
                let y = Double(high - pitch) * rowHeight
                context.fill(Path(CGRect(x: 64, y: y, width: viewWidth - 64, height: rowHeight - 1)),
                             with: .color([1,3,6,8,10].contains(pitch % 12) ? .gray.opacity(0.14) : .gray.opacity(0.05)))
                context.draw(Text(MIDIPitch(pitch)!.displayName).font(.caption2), at: CGPoint(x: 28, y: y + rowHeight / 2))
            }
            let firstBeat = max(Int(offset / 62), 0)
            for index in firstBeat...(firstBeat + Int(viewWidth / 62) + 1) {
                let x = 64 + Double(index) * 62 - offset
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: viewHeight))
                context.stroke(line, with: .color(.gray.opacity(index % 4 == 0 ? 0.5 : 0.2)), lineWidth: 1)
            }
            let byID = Dictionary(uniqueKeysWithValues: results.compactMap { result in result.expectedID.map { ($0, result) } })
            for note in pattern.notes {
                let x = 64 + Double(note.onsetNanoseconds) * scale - offset
                let width = max(Double(note.durationNanoseconds ?? 0) * scale, 8)
                guard x + width >= 64, x <= viewWidth else { continue }
                let rect = CGRect(x: max(x, 64), y: Double(high - Int(note.pitch.noteNumber)) * rowHeight + 2,
                                  width: min(width - max(64 - x, 0), viewWidth - max(x, 64)), height: max(rowHeight - 4, 4))
                let result = byID[note.id]
                let color: Color = result == nil ? .blue.opacity(0.7)
                    : (result?.classification == .correct ? (gradeDuration && result?.durationPassed == false ? .orange : .green) : .red.opacity(0.8))
                context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color))
            }
            if playheadNanoseconds != nil {
                let x = 64 + playhead - offset
                var line = Path(); line.move(to: CGPoint(x: x, y: 0)); line.addLine(to: CGPoint(x: x, y: viewHeight))
                context.stroke(line, with: .color(.blue), lineWidth: 2)
            }
        }
        .frame(height: 290)
        .accessibilityLabel("Piano roll for \(pattern.exercise.displayName)")
        .accessibilityValue("\(pattern.notes.count) notes at \(Int(pattern.bpm)) BPM; bars indicate key hold duration.")
    }
}

struct PianoCalibrationView: View {
    @ObservedObject var state: AppState
    @ObservedObject var piano: PianoPracticeController
    init(state: AppState) { self.state = state; self.piano = state.piano }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Piano timing alignment").font(.largeTitle.bold())
                PianoDeviceControls(state: state)
                Text("Keep your normal headphone output selected. After the count-in, play one key once on each of 12 clicks at 60 BPM. This measures your consistent playing offset for this piano and output, including your response to the click.")
                    .foregroundStyle(.secondary)
                if let profile = state.activeTimingAlignmentProfile {
                    Text("Saved correction: \(profile.compensationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms, from \(profile.sampleCount) notes.")
                    Button("Delete saved alignment") { state.deleteActiveTimingAlignment() }
                }
                switch state.timingAlignmentPhase {
                case .idle: Text("Ready")
                case .starting: Text("Starting the click…")
                case let .countIn(remaining): Text("Count-in: \(remaining) clicks remaining")
                case let .collecting(count, target, hits): Text("Click \(count)/\(target) • \(hits) notes detected")
                case let .review(profile):
                    Text("Measured correction: \(profile.compensationMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms")
                    Button("Save alignment") { state.saveTimingAlignment() }
                case .saved: Text("Alignment saved for this piano and output.")
                case let .error(message): Text(message).foregroundStyle(.orange)
                }
                if let beat = state.timingAlignmentVisibleBeat { Text("\(beat)").font(.system(size: 54, weight: .bold)).foregroundStyle(.blue) }
                HStack {
                    Button("Start alignment") { state.startTimingAlignment() }
                        .disabled(piano.phase.isActive || state.timingAlignmentPhase.isActive || state.isRefreshingAudioEngine)
                    Button("Cancel") { state.cancelTimingAlignment() }
                }
            }.padding(24)
        }.task { state.startHardwareMonitoring() }
    }
}
