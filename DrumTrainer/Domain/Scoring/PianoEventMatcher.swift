import Foundation

struct PianoEventMatcher: Sendable {
    func score(pattern: PianoPracticePattern, actual: [PianoPlayedNote],
               configuration: PianoScoringConfiguration = PianoScoringConfiguration(),
               droppedCount: Int = 0, inputIssueCount: Int = 0) -> PianoPracticeOutcome {
        let expected = pattern.notes.sorted {
            $0.onsetNanoseconds == $1.onsetNanoseconds
                ? $0.id.uuidString < $1.id.uuidString : $0.onsetNanoseconds < $1.onsetNanoseconds
        }
        let played = actual.sorted {
            $0.onsetNanoseconds == $1.onsetNanoseconds
                ? $0.id.uuidString < $1.id.uuidString : $0.onsetNanoseconds < $1.onsetNanoseconds
        }
        let tolerance = Double(max(configuration.onsetToleranceNanoseconds, 1))
        func time(_ note: PianoPlayedNote) -> Double {
            Double(note.onsetNanoseconds) - Double(configuration.timingCompensationNanoseconds)
        }
        var components: [[PitchedExpectedNote]] = []
        for note in expected {
            if let last = components.last?.last,
               Double(note.onsetNanoseconds) - Double(last.onsetNanoseconds) <= tolerance * 2 {
                components[components.count - 1].append(note)
            } else { components.append([note]) }
        }
        var results: [PianoNoteResult] = []
        var used: Set<UUID> = []
        var overloads = 0
        for component in components {
            let start = Double(component[0].onsetNanoseconds) - tolerance
            let end = Double(component[component.count - 1].onsetNanoseconds) + tolerance
            let candidates = played.filter { !used.contains($0.id) && time($0) >= start && time($0) <= end }
            // Bound dense/flooded matching work. Such evidence is explicitly unverified.
            guard component.count <= 128, candidates.count <= 512 else {
                overloads += 1
                for note in component { results.append(result(expected: note, actual: nil, classification: .unverified, configuration: configuration)) }
                continue
            }
            let costs = component.map { note in
                candidates.map { actual -> Double in
                    let error = abs(time(actual) - Double(note.onsetNanoseconds))
                    guard error <= tolerance else { return 1_000_000 }
                    // Matching consumes an otherwise-extra note (cost 1).
                    return (note.pitch == actual.pitch ? 0 : 1.1) + error / tolerance * 0.49 - 1
                } + Array(repeating: 1.0, count: component.count)
            }
            let assignment = minimumAssignment(costs)
            for (index, note) in component.enumerated() {
                let column = assignment[index]
                if column < candidates.count, costs[index][column] < 1_000_000 {
                    let actual = candidates[column]
                    used.insert(actual.id)
                    let classification: PianoMatchClassification = actual.isUncertain || actual.isInterrupted
                        ? .unverified : (actual.pitch == note.pitch ? .correct : .wrongPitch)
                    results.append(result(expected: note, actual: actual, classification: classification, configuration: configuration))
                } else { results.append(result(expected: note, actual: nil, classification: .missed, configuration: configuration)) }
            }
        }
        for note in played where !used.contains(note.id) {
            results.append(result(expected: nil, actual: note,
                classification: note.isUncertain || note.isInterrupted ? .unverified : .extra, configuration: configuration))
        }
        let actualByID = Dictionary(uniqueKeysWithValues: played.map { ($0.id, $0) })
        let groups = Dictionary(grouping: expected.filter { $0.chordID != nil }, by: { $0.chordID! })
        let chords = groups.map { id, notes -> PianoChordResult in
            let ids = Set(notes.map(\.id))
            let matches = results.filter { $0.expectedID.map(ids.contains) == true && $0.classification == .correct }
            let times = matches.compactMap { $0.actualID.flatMap { actualByID[$0] }.map(time) }
            let spread = times.count >= 2 ? (times.max()! - times.min()!) / 1_000_000 : nil
            let hasExtra = played.contains { !used.contains($0.id) && abs(time($0) - Double(notes[0].onsetNanoseconds)) <= tolerance }
            return PianoChordResult(id: id, expectedCount: notes.count, correctCount: matches.count,
                spreadMilliseconds: spread,
                passes: matches.count == notes.count && !hasExtra
                    && (spread ?? .infinity) <= Double(configuration.chordSpreadToleranceNanoseconds) / 1_000_000)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
        return PianoPracticeOutcome(pattern: pattern, actualNotes: played, results: results, chords: chords,
            configuration: configuration, droppedCount: droppedCount, inputIssueCount: inputIssueCount + overloads)
    }

    private func result(expected: PitchedExpectedNote?, actual: PianoPlayedNote?, classification: PianoMatchClassification,
                        configuration: PianoScoringConfiguration) -> PianoNoteResult {
        let onset = expected.flatMap { expected in actual.map {
            (Double($0.onsetNanoseconds) - Double(configuration.timingCompensationNanoseconds) - Double(expected.onsetNanoseconds)) / 1_000_000
        } }
        let durationError = expected?.durationNanoseconds.flatMap { expectedDuration in actual.flatMap { note in
            note.keyReleaseNanoseconds.map { (Double($0) - Double(note.onsetNanoseconds) - Double(expectedDuration)) / 1_000_000 }
        } }
        return PianoNoteResult(id: expected?.id ?? actual!.id, expectedID: expected?.id, actualID: actual?.id,
            expectedPitch: expected?.pitch, actualPitch: actual?.pitch, classification: classification,
            onsetErrorMilliseconds: onset, durationErrorMilliseconds: durationError,
            durationPassed: durationError.map { abs($0) <= Double(configuration.durationToleranceNanoseconds) / 1_000_000 })
    }

    /// Rectangular Hungarian assignment; dummy columns allow every expected note
    /// to be missed. Arrival order inside chords imposes no matching constraint.
    private func minimumAssignment(_ costs: [[Double]]) -> [Int] {
        guard let first = costs.first else { return [] }
        let n = costs.count, m = first.count
        var u = Array(repeating: 0.0, count: n + 1), v = Array(repeating: 0.0, count: m + 1)
        var p = Array(repeating: 0, count: m + 1), way = Array(repeating: 0, count: m + 1)
        for row in 1...n {
            p[0] = row
            var column = 0
            var minimum = Array(repeating: Double.infinity, count: m + 1)
            var visited = Array(repeating: false, count: m + 1)
            repeat {
                visited[column] = true
                let currentRow = p[column]
                var delta = Double.infinity, nextColumn = 0
                for candidate in 1...m where !visited[candidate] {
                    let cost = costs[currentRow - 1][candidate - 1] - u[currentRow] - v[candidate]
                    if cost < minimum[candidate] { minimum[candidate] = cost; way[candidate] = column }
                    if minimum[candidate] < delta { delta = minimum[candidate]; nextColumn = candidate }
                }
                for candidate in 0...m {
                    if visited[candidate] { u[p[candidate]] += delta; v[candidate] -= delta }
                    else { minimum[candidate] -= delta }
                }
                column = nextColumn
            } while p[column] != 0
            repeat {
                let previous = way[column]
                p[column] = p[previous]
                column = previous
            } while column != 0
        }
        var assignment = Array(repeating: m, count: n)
        for column in 1...m where p[column] != 0 { assignment[p[column] - 1] = column - 1 }
        return assignment
    }
}
