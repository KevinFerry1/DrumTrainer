import SwiftUI

enum InstrumentWorkspaceSection {
    case liveMonitor, calibration, practice, history

    var title: String {
        switch self {
        case .liveMonitor: "Instrument setup"
        case .calibration: "Calibration coming soon"
        case .practice: "Practice coming soon"
        case .history: "No sessions yet"
        }
    }
}

struct InstrumentSetupView: View {
    @ObservedObject var state: AppState
    let section: InstrumentWorkspaceSection

    private var profile: InstrumentProfile { state.activeInstrumentProfile }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label(state.selectedInstrument.displayName, systemImage: state.selectedInstrument.symbol)
                    .font(.largeTitle.bold())
                Text(section.title).font(.title2.bold())
                Text(state.selectedInstrument == .electricPiano
                     ? "Piano practice is available in the Practice tab. Saving piano sessions to History comes in the next phase."
                     : "Guitar pitch detection, tablature, and practice grading are planned for a later phase. You can save your preferred setup now.")
                    .foregroundStyle(.secondary)

                if section == .liveMonitor {
                    GroupBox("Preferred setup") {
                        VStack(alignment: .leading, spacing: 16) {
                            Stepper("Practice tempo: \(Int(state.practiceBPM)) BPM",
                                    value: $state.practiceBPM, in: 40...240, step: 1)
                            Picker("MIDI input", selection: Binding(
                                get: { profile.midiInputID },
                                set: { id in state.updateActiveInstrumentProfile { $0.midiInputID = id } }
                            )) {
                                Text("None").tag(Optional<Int32>.none)
                                ForEach(state.midiDevices) { device in
                                    Text(device.name).tag(Optional(device.id))
                                }
                                if let id = profile.midiInputID, !state.midiDevices.contains(where: { $0.id == id }) {
                                    Text("Saved input (disconnected)").tag(Optional(id))
                                }
                            }
                            Picker("Audio input", selection: Binding(
                                get: { profile.audioInputUID },
                                set: { uid in state.updateActiveInstrumentProfile { $0.audioInputUID = uid } }
                            )) {
                                Text("None").tag(Optional<String>.none)
                                ForEach(state.audioDevices) { device in
                                    Text(device.name).tag(Optional(device.uid))
                                }
                                if let uid = profile.audioInputUID, !state.audioDevices.contains(where: { $0.uid == uid }) {
                                    Text("Saved input (disconnected)").tag(Optional(uid))
                                }
                            }
                            Picker("Audio output", selection: Binding(
                                get: { profile.audioOutputUID },
                                set: { uid in state.updateActiveInstrumentProfile { $0.audioOutputUID = uid } }
                            )) {
                                Text("System Default").tag(Optional<String>.none)
                                ForEach(state.audioOutputDevices) { device in
                                    Text(device.name).tag(Optional(device.uid))
                                }
                                if let uid = profile.audioOutputUID, !state.audioOutputDevices.contains(where: { $0.uid == uid }) {
                                    Text("Saved output (disconnected)").tag(Optional(uid))
                                }
                            }
                            Text("These choices are remembered for this instrument. Note monitoring and grading will become available with practice support.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }
                }
                if let error = state.instrumentProfileSaveError {
                    Text(error).font(.callout).foregroundStyle(.red)
                } else if let message = state.instrumentStatusMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if section == .history {
                    Text("Your saved drum sessions are available when you switch back to Drums.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .task { state.startHardwareMonitoring() }
    }
}
