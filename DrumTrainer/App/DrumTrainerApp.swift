import SwiftUI
import UniformTypeIdentifiers

@main
struct DrumTrainerApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("Drum Performance Trainer") {
            TabView {
                LiveMonitorView(state: appState)
                    .tabItem { Label("Live Monitor", systemImage: "waveform.path.ecg") }
                CalibrationView(state: appState)
                    .tabItem { Label("Calibration", systemImage: "tuningfork") }
                PracticeView(state: appState)
                    .tabItem { Label("Practice", systemImage: "metronome") }
                HistoryView(state: appState)
                    .tabItem { Label("History", systemImage: "chart.xyaxis.line") }
            }
            .frame(minWidth: 980, minHeight: 720)
        }
    }
}

private struct HistoryView: View {
    @ObservedObject var state: AppState
    @State private var selectedMetric: HistoryMetric = .recall
    @State private var pendingSessionDeletion: PracticeSessionSummary?
    @State private var showsClearHistoryConfirmation = false
    @State private var selectedSession: PracticeSessionSummary?
    @State private var showsExporter = false
    @State private var showsImporter = false
    @State private var exportDocument = PracticeDataDocument(data: Data())
    @State private var transferError: String?

    private enum HistoryMetric: String, CaseIterable, Identifiable {
        case recall
        case timingError
        case limbSpread

        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .recall: "Recall"
            case .timingError: "Median timing error"
            case .limbSpread: "Median limb spread"
            }
        }

        var unit: String { self == .recall ? "%" : "ms" }

        func value(for session: PracticeSessionSummary) -> Double? {
            switch self {
            case .recall: session.recall * 100
            case .timingError: session.medianAbsoluteErrorMilliseconds
            case .limbSpread: session.medianLimbSpreadMilliseconds
            }
        }
    }

    private struct ExerciseProgress: Identifiable {
        var id: String { name }
        let name: String
        let sessionCount: Int
        let bestRecall: Double
        let cleanTempo: Double?
        let verifiedCeiling: Double?
        let latestDate: Date
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Practice History").font(.title.bold())
                        Text("Local session summaries, trends, and clean-tempo records")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Import JSON", systemImage: "square.and.arrow.down") {
                        showsImporter = true
                    }
                    Button("Export JSON", systemImage: "square.and.arrow.up") {
                        do {
                            exportDocument = PracticeDataDocument(data: try state.exportPracticeData())
                            showsExporter = true
                        } catch {
                            transferError = error.localizedDescription
                        }
                    }
                    if !state.practiceHistory.isEmpty {
                        Button("Clear History", role: .destructive) {
                            showsClearHistoryConfirmation = true
                        }
                    }
                }

                if state.practiceHistory.isEmpty {
                    ContentUnavailableView(
                        "No completed sessions yet",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Finish an exercise and its progress summary will appear here automatically.")
                    )
                    .frame(minHeight: 420)
                } else {
                    overview
                    trend
                    personalBests
                    recentSessions
                }

                if let message = state.practiceDataStatusMessage {
                    Label(message, systemImage: "externaldrive.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
        .navigationTitle("History")
        .sheet(item: $selectedSession) { session in
            PracticeSessionDetailView(state: state, sessionID: session.id)
        }
        .fileExporter(
            isPresented: $showsExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: "DrumTrainer-Practice-Data"
        ) { result in
            if case let .failure(error) = result { transferError = error.localizedDescription }
        }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let didAccess = url.startAccessingSecurityScopedResource()
                defer { if didAccess { url.stopAccessingSecurityScopedResource() } }
                try state.importPracticeData(Data(contentsOf: url))
            } catch {
                transferError = error.localizedDescription
            }
        }
        .alert("Practice data transfer failed", isPresented: Binding(
            get: { transferError != nil },
            set: { if !$0 { transferError = nil } }
        )) {
            Button("OK") { transferError = nil }
        } message: {
            Text(transferError ?? "Unknown error")
        }
        .alert(
            "Delete session?",
            isPresented: Binding(
                get: { pendingSessionDeletion != nil },
                set: { if !$0 { pendingSessionDeletion = nil } }
            ),
            presenting: pendingSessionDeletion
        ) { session in
            Button("Delete Session", role: .destructive) {
                state.deletePracticeSession(id: session.id)
                pendingSessionDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingSessionDeletion = nil }
        } message: { session in
            Text("Delete the saved \(session.exerciseName) summary from \(session.completedAt.formatted(date: .abbreviated, time: .shortened))?")
        }
        .confirmationDialog(
            "Clear all practice history?",
            isPresented: $showsClearHistoryConfirmation,
            titleVisibility: .visible
        ) {
            Button("Clear All Sessions", role: .destructive) { state.clearPracticeHistory() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved custom exercises are kept. This removes all session summaries and cannot be undone.")
        }
    }

    private var overview: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
            historyCard("Sessions", "\(state.practiceHistory.count)", "Completed runs")
            historyCard(
                "Practice time",
                totalPracticeSeconds.formatted(.number.precision(.fractionLength(0))) + " s",
                "Scored exercise time"
            )
            historyCard(
                "Best recall",
                bestRecall.formatted(.percent.precision(.fractionLength(1))),
                "Any completed run"
            )
            historyCard(
                "Clean sessions",
                "\(state.practiceHistory.count(where: \.isClean))",
                "≥95% recall and ≤25 ms"
            )
        }
    }

    private var trend: some View {
        GroupBox("Progress trend") {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("Metric", selection: $selectedMetric) {
                        ForEach(HistoryMetric.allCases) { metric in
                            Text(metric.displayName).tag(metric)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    Spacer()
                    Text("Last \(trendSessions.count) sessions")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if trendValues.isEmpty {
                    ContentUnavailableView(
                        "No \(selectedMetric.displayName.lowercased()) data",
                        systemImage: "chart.line.downtrend.xyaxis",
                        description: Text("This metric appears after a compatible exercise is completed.")
                    )
                    .frame(height: 150)
                } else {
                    Canvas { context, size in
                        drawTrend(context: &context, size: size)
                    }
                    .frame(height: 190)
                    .background(.quaternary.opacity(0.24), in: RoundedRectangle(cornerRadius: 10))
                    .accessibilityLabel("\(selectedMetric.displayName) trend across \(trendValues.count) sessions")

                    HStack {
                        Text(trendValues.first.map { formatTrendValue($0.value) } ?? "—")
                        Spacer()
                        Text("Older → newer")
                        Spacer()
                        Text(trendValues.last.map { formatTrendValue($0.value) } ?? "—")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var personalBests: some View {
        GroupBox("Exercise progress") {
            Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                GridRow {
                    Text("Exercise")
                    Text("Sessions")
                    Text("Best recall")
                    Text("Highest clean tempo")
                    Text("Verified ceiling")
                    Text("Last practiced")
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)

                ForEach(exerciseProgress) { progress in
                    GridRow {
                        Text(progress.name).fontWeight(.semibold)
                        Text("\(progress.sessionCount)")
                        Text(progress.bestRecall.formatted(.percent.precision(.fractionLength(1))))
                        Text(progress.cleanTempo.map { "\(Int($0.rounded())) BPM" } ?? "—")
                        Text(progress.verifiedCeiling.map { "\(Int($0.rounded())) BPM" } ?? "—")
                        Text(progress.latestDate, format: .dateTime.month(.abbreviated).day().year())
                    }
                    .monospacedDigit()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var recentSessions: some View {
        GroupBox("Recent sessions") {
            LazyVStack(spacing: 0) {
                ForEach(state.practiceHistory.prefix(100)) { session in
                    HStack(spacing: 18) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.exerciseName).fontWeight(.semibold)
                            Text(session.completedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(minWidth: 190, alignment: .leading)
                        Text("\(Int(session.bpm.rounded())) BPM")
                            .frame(width: 76, alignment: .trailing)
                        Text(session.recall.formatted(.percent.precision(.fractionLength(1))))
                            .frame(width: 72, alignment: .trailing)
                        Text(session.medianAbsoluteErrorMilliseconds.map { $0.formatted(.number.precision(.fractionLength(1))) + " ms" } ?? "—")
                            .frame(width: 84, alignment: .trailing)
                        if session.isClean {
                            Label("Clean", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                                .font(.caption)
                        } else {
                            Text("Needs work").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Details") { selectedSession = session }
                            .buttonStyle(.bordered)
                        Button(role: .destructive) {
                            pendingSessionDeletion = session
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this session summary")
                    }
                    .padding(.vertical, 9)
                    .monospacedDigit()
                    Divider()
                }
            }
        }
    }

    private var totalPracticeSeconds: Double {
        state.practiceHistory.reduce(0) { $0 + $1.durationSeconds }
    }

    private var bestRecall: Double {
        state.practiceHistory.map(\.recall).max() ?? 0
    }

    private var trendSessions: [PracticeSessionSummary] {
        Array(state.practiceHistory.prefix(30).reversed())
    }

    private var trendValues: [(index: Int, value: Double)] {
        trendSessions.enumerated().compactMap { index, session in
            selectedMetric.value(for: session).map { (index, $0) }
        }
    }

    private var exerciseProgress: [ExerciseProgress] {
        Dictionary(grouping: state.practiceHistory, by: \.exerciseName)
            .map { name, sessions in
                ExerciseProgress(
                    name: name,
                    sessionCount: sessions.count,
                    bestRecall: sessions.map(\.recall).max() ?? 0,
                    cleanTempo: sessions.filter(\.isClean).map(\.bpm).max(),
                    verifiedCeiling: state.ceilingRecords
                        .filter { $0.exerciseName == name }
                        .map(\.highestVerifiedBPM)
                        .max(),
                    latestDate: sessions.map(\.completedAt).max() ?? .distantPast
                )
            }
            .sorted { $0.latestDate > $1.latestDate }
    }

    private func historyCard(_ title: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func drawTrend(context: inout GraphicsContext, size: CGSize) {
        let values = trendValues
        guard !values.isEmpty else { return }
        let inset: CGFloat = 16
        let plotWidth = max(size.width - inset * 2, 1)
        let plotHeight = max(size.height - inset * 2, 1)
        let rawValues = values.map(\.value)
        let minimum = selectedMetric == .recall ? 0 : min(rawValues.min() ?? 0, 0)
        let maximum = selectedMetric == .recall ? 100 : max(rawValues.max() ?? 1, 1)
        let range = max(maximum - minimum, 1)
        let denominator = max(trendSessions.count - 1, 1)

        for fraction in [0.0, 0.5, 1.0] {
            let y = inset + plotHeight * CGFloat(fraction)
            var grid = Path()
            grid.move(to: CGPoint(x: inset, y: y))
            grid.addLine(to: CGPoint(x: size.width - inset, y: y))
            context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 1)
        }

        let points = values.map { item in
            let x = inset + CGFloat(item.index) / CGFloat(denominator) * plotWidth
            let normalized = (item.value - minimum) / range
            let y = inset + (1 - CGFloat(normalized)) * plotHeight
            return CGPoint(x: x, y: y)
        }
        var line = Path()
        if let first = points.first {
            line.move(to: first)
            for point in points.dropFirst() { line.addLine(to: point) }
        }
        context.stroke(line, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        for point in points {
            context.fill(Path(ellipseIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)), with: .color(.accentColor))
        }
    }

    private func formatTrendValue(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " \(selectedMetric.unit)"
    }
}

private struct PracticeDataDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw PracticeDataPersistenceError.unreadableData
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct PracticeSessionDetailView: View {
    @ObservedObject var state: AppState
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var notes = ""
    @State private var tagsText = ""

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let summary {
                        header(summary)
                        summaryCards(summary)
                    }

                    if let record {
                        evidence(record)
                        deviceContext(record.deviceContext)
                        metadataEditor(record)
                        voiceBreakdown(record.summary)
                        eventLedger(record)
                    } else {
                        ContentUnavailableView(
                            "Detailed evidence unavailable",
                            systemImage: "archivebox",
                            description: Text("This is a legacy schema-v1 summary. New sessions preserve events, devices, calibration, notes, tags, and rescoring data.")
                        )
                        .frame(minHeight: 240)
                    }
                }
                .padding(20)
            }
            .navigationTitle(summary?.exerciseName ?? "Session Details")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if record != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Rescore Saved Events", systemImage: "arrow.clockwise") {
                            state.rescorePracticeSession(id: sessionID)
                        }
                    }
                }
            }
        }
        .frame(minWidth: 780, minHeight: 680)
        .onAppear { loadMetadata() }
    }

    private var record: PracticeSessionRecord? { state.practiceSessionRecord(id: sessionID) }
    private var summary: PracticeSessionSummary? {
        state.practiceHistory.first { $0.id == sessionID } ?? record?.summary
    }

    private func header(_ summary: PracticeSessionSummary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary.completedAt.formatted(date: .long, time: .shortened))
                    .foregroundStyle(.secondary)
                Text("\(Int(summary.bpm.rounded())) BPM · \(summary.measures) measures · scoring v\(summary.scoringVersion)")
                    .font(.callout.monospacedDigit())
            }
            Spacer()
            Label(summary.isClean ? "Clean" : "Needs work", systemImage: summary.isClean ? "checkmark.seal.fill" : "scope")
                .foregroundStyle(summary.isClean ? .green : .secondary)
        }
    }

    private func summaryCards(_ summary: PracticeSessionSummary) -> some View {
        HStack(spacing: 12) {
            detailCard("Recall", summary.recall.formatted(.percent.precision(.fractionLength(1))))
            detailCard("Precision", summary.precision.formatted(.percent.precision(.fractionLength(1))))
            detailCard("Median error", summary.medianAbsoluteErrorMilliseconds.map { formatMilliseconds($0) } ?? "—")
            detailCard("Correct", "\(summary.correctCount)/\(summary.totalExpected)")
        }
    }

    private func evidence(_ record: PracticeSessionRecord) -> some View {
        GroupBox("Archived scoring evidence") {
            HStack(spacing: 24) {
                Label("\(record.pattern.expectedEvents.count) expected", systemImage: "music.note.list")
                Label("\(record.actualEvents.count) played", systemImage: "waveform")
                Label("\(record.matchResults.count) match decisions", systemImage: "point.3.connected.trianglepath.dotted")
                if record.summary.droppedEventCount > 0 {
                    Label("\(record.summary.droppedEventCount) dropped", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(.vertical, 6)
        }
    }

    private func deviceContext(_ context: PracticeSessionDeviceContext) -> some View {
        GroupBox("Session devices and calibration") {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                contextRow("MIDI input", context.midiDeviceName ?? "Not connected")
                contextRow("Audio input", context.audioInputName ?? "Not connected")
                contextRow("Click output", context.audioOutputName ?? "System Default")
                if let calibration = context.calibrationProfile {
                    contextRow("Calibration", "\(calibration.quality.displayName) · \(calibration.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    contextRow("Calibration ID", calibration.id.uuidString)
                } else {
                    contextRow("Calibration", "None linked")
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func contextRow(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func metadataEditor(_ record: PracticeSessionRecord) -> some View {
        GroupBox("Notes and tags") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Tags, separated by commas", text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                TextEditor(text: $notes)
                    .frame(minHeight: 90)
                    .padding(4)
                    .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 7))
                HStack {
                    Text(record.tags.isEmpty ? "Use tags to group song sections, techniques, or goals." : "Saved tags: \(record.tags.joined(separator: ", "))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Save Notes & Tags") {
                        state.updatePracticeSessionMetadata(
                            id: sessionID,
                            notes: notes,
                            tags: tagsText.split(separator: ",").map(String.init)
                        )
                        loadMetadata()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func voiceBreakdown(_ summary: PracticeSessionSummary) -> some View {
        GroupBox("Voice breakdown") {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 7) {
                GridRow {
                    Text("Voice"); Text("Correct"); Text("Recall"); Text("Precision"); Text("Median error")
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                ForEach(summary.voiceSummaries, id: \.voice) { voice in
                    GridRow {
                        Text(voice.voice.displayName).fontWeight(.semibold)
                        Text("\(voice.correctCount)/\(voice.totalExpected)")
                        Text(voice.recall.formatted(.percent.precision(.fractionLength(1))))
                        Text(voice.precision.formatted(.percent.precision(.fractionLength(1))))
                        Text(voice.medianAbsoluteErrorMilliseconds.map { formatMilliseconds($0) } ?? "—")
                    }
                    .monospacedDigit()
                }
            }
            .padding(.vertical, 6)
        }
    }

    private func eventLedger(_ record: PracticeSessionRecord) -> some View {
        GroupBox("Timing ledger") {
            LazyVStack(spacing: 0) {
                ForEach(record.outcome.timingTimeline.entries.prefix(250)) { entry in
                    HStack(spacing: 14) {
                        Text(entry.classification.rawValue.capitalized)
                            .frame(width: 92, alignment: .leading)
                            .foregroundStyle(entry.classification == .correct ? .green : .orange)
                        Text(entry.measure.map { "M\($0) B\(entry.beat ?? 0).\(entry.subdivision ?? 0)" } ?? "Extra")
                            .frame(width: 86, alignment: .leading)
                        Text(entry.expectedVoice?.displayName ?? "—")
                            .frame(width: 105, alignment: .leading)
                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                        Text(entry.playedVoice?.displayName ?? "—")
                            .frame(width: 105, alignment: .leading)
                        Spacer()
                        Text(entry.signedOffsetMilliseconds.map { String(format: "%+.1f ms", $0) } ?? "—")
                            .monospacedDigit()
                    }
                    .font(.callout)
                    .padding(.vertical, 6)
                    Divider()
                }
                if record.matchResults.count > 250 {
                    Text("Showing the first 250 of \(record.matchResults.count) match decisions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
            }
        }
    }

    private func detailCard(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.bold().monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private func formatMilliseconds(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + " ms"
    }

    private func loadMetadata() {
        guard let record else { return }
        notes = record.notes
        tagsText = record.tags.joined(separator: ", ")
    }
}
