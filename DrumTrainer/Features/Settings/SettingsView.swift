import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings").font(.title.bold())
                    Text("Your preferences for DrumTrainer")
                        .foregroundStyle(.secondary)
                }

                if state.selectedInstrument == .electricPiano {
                    Text("Auto go currently applies to drums. Piano automatic replay and tempo progression come in the next phase.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                GroupBox("Practice") {
                    VStack(alignment: .leading, spacing: 14) {
                        Toggle("Auto go", isOn: $state.practiceAutoGoEnabled)
                            .toggleStyle(.switch)
                        Text("Automatically start the next round after reviewing your results, with the usual count-in.")
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if state.practiceAutoGoEnabled {
                            Divider()
                            HStack(spacing: 12) {
                                Text("Show results for")
                                Slider(value: $state.practiceAutoGoDelaySeconds, in: 1...30, step: 1)
                                    .accessibilityLabel("Auto go results delay")
                                Text("\(Int(state.practiceAutoGoDelaySeconds)) seconds")
                                    .monospacedDigit()
                                    .frame(width: 86, alignment: .trailing)
                            }
                            Text("Choose 1–30 seconds. Stop Auto go pauses results so you can review them; Play Again resumes automatic repeats. Turn this switch off to disable Auto go.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Use Play Again on the results page when you’re ready for another round.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                Text("Preferences save automatically and are remembered when you reopen the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
        .navigationTitle("Settings")
    }
}
