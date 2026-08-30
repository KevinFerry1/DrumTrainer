import SwiftUI

struct PracticeScoreView: View {
    let pattern: PracticePattern
    var playheadSessionTime: Int64?
    var sessionStartTime: Int64?
    var sessionEndTime: Int64?
    var classifications: [UUID: MatchClassification] = [:]
    var previewOnly = false
    var fixedMeasureWidth: Double?

    var body: some View {
        GeometryReader { geometry in
            let measureWidth = fixedMeasureWidth ?? max(330.0, min(460.0, geometry.size.width * 0.78))
            let displayedMeasures = previewOnly ? 1 : pattern.measures
            let contentWidth = 58 + measureWidth * Double(displayedMeasures)
            let playheadX = scorePosition(
                for: playheadSessionTime,
                start: sessionStartTime,
                end: sessionEndTime,
                measureWidth: measureWidth,
                measureCount: displayedMeasures
            )
            let offset = viewportOffset(
                playheadX: playheadX,
                contentWidth: contentWidth,
                viewportWidth: geometry.size.width
            )

            Canvas { context, size in
                drawScore(
                    context: &context,
                    size: size,
                    measureWidth: measureWidth,
                    measureCount: displayedMeasures,
                    viewportOffset: offset,
                    playheadX: playheadX
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .textBackgroundColor).opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
            )
        }
        .frame(height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Drum notation for \(pattern.name)")
        .accessibilityValue(accessibilityDescription)
    }

    private func drawScore(
        context: inout GraphicsContext,
        size: CGSize,
        measureWidth: Double,
        measureCount: Int,
        viewportOffset: Double,
        playheadX: Double?
    ) {
        let staffTop = 52.0
        let staffSpacing = 10.0
        let staffBottom = staffTop + staffSpacing * 4
        let slotsPerBeat = pattern.subdivision.notesPerBeat
        let visibleMinX = viewportOffset - measureWidth
        let visibleMaxX = viewportOffset + size.width + measureWidth

        for measureIndex in 0..<measureCount {
            let signature = pattern.signature(forMeasure: measureIndex + 1)
            let beatsInMeasure = signature.numerator
            let slotsPerMeasure = slotsPerBeat * beatsInMeasure
            let measureLeft = 48 + Double(measureIndex) * measureWidth
            let measureRight = measureLeft + measureWidth
            guard measureRight >= visibleMinX, measureLeft <= visibleMaxX else { continue }

            for line in 0..<5 {
                let y = staffTop + Double(line) * staffSpacing
                strokeLine(
                    from: CGPoint(x: measureLeft - viewportOffset, y: y),
                    to: CGPoint(x: measureRight - viewportOffset, y: y),
                    color: .primary.opacity(0.72),
                    width: 1,
                    context: &context
                )
            }

            strokeLine(
                from: CGPoint(x: measureLeft - viewportOffset, y: staffTop),
                to: CGPoint(x: measureLeft - viewportOffset, y: staffBottom),
                color: .primary.opacity(0.85),
                width: measureIndex == 0 ? 1.5 : 1,
                context: &context
            )
            strokeLine(
                from: CGPoint(x: measureRight - viewportOffset, y: staffTop),
                to: CGPoint(x: measureRight - viewportOffset, y: staffBottom),
                color: .primary.opacity(0.9),
                width: measureIndex == measureCount - 1 ? 3 : 1.5,
                context: &context
            )

            drawLabel(
                "Measure \(measureIndex + 1)",
                at: CGPoint(x: measureLeft + 8 - viewportOffset, y: 25),
                font: .caption,
                color: .secondary,
                anchor: .leading,
                context: &context
            )

            if measureIndex == 0 {
                drawPercussionClef(atX: measureLeft + 15 - viewportOffset, staffTop: staffTop, context: &context)
            }
            drawTimeSignature(
                numerator: signature.numerator,
                denominator: signature.denominator,
                atX: measureLeft + 36 - viewportOffset,
                staffTop: staffTop,
                context: &context
            )

            for beat in 0..<beatsInMeasure {
                let beatStartSlot = beat * slotsPerBeat
                let beatEndSlot = beatStartSlot + slotsPerBeat
                let beatLeft = PracticeScoreTimeline.notePosition(
                    measure: measureIndex,
                    slot: Double(beatStartSlot) - 0.35,
                    slotsPerMeasure: slotsPerMeasure,
                    measureWidth: measureWidth
                ) - viewportOffset
                let beatRight = PracticeScoreTimeline.notePosition(
                    measure: measureIndex,
                    slot: Double(beatEndSlot) - 0.35,
                    slotsPerMeasure: slotsPerMeasure,
                    measureWidth: measureWidth
                ) - viewportOffset
                context.fill(
                    Path(CGRect(x: beatLeft, y: 17, width: beatRight - beatLeft, height: 139)),
                    with: .color(Color.accentColor.opacity(beat.isMultiple(of: 2) ? 0.045 : 0.018))
                )
                strokeLine(
                    from: CGPoint(x: beatLeft, y: 18),
                    to: CGPoint(x: beatLeft, y: 154),
                    color: .secondary.opacity(0.2),
                    width: 1,
                    context: &context
                )

                for slotInBeat in 0..<slotsPerBeat {
                    let slot = beatStartSlot + slotInBeat
                    let x = xPosition(
                        measure: measureIndex,
                        slot: slot,
                        slotsPerMeasure: slotsPerMeasure,
                        measureWidth: measureWidth
                    ) - viewportOffset
                    if !usesContinuousTiming,
                       expectedEvents(
                        measure: measureIndex + 1,
                        beat: beat + 1,
                        subdivision: slotInBeat
                       ).isEmpty {
                        drawRest(at: CGPoint(x: x, y: staffBottom - 12), context: &context)
                    }

                    drawLabel(
                        countLabel(beat: beat, subdivision: slotInBeat),
                        at: CGPoint(x: x, y: 121),
                        font: .caption2.monospaced(),
                        color: slotInBeat == 0 ? .primary.opacity(0.8) : .secondary.opacity(0.75),
                        anchor: .center,
                        context: &context
                    )
                }

                let beatEvents = pattern.expectedEvents.filter {
                    $0.measure == measureIndex + 1 && $0.beat == beat + 1
                }
                let notePoints = uniqueNoteXPositions(beatEvents.map { event in
                    eventXPosition(
                        event,
                        measureIndex: measureIndex,
                        slotsPerMeasure: slotsPerMeasure,
                        measureWidth: measureWidth
                    ) - viewportOffset
                }).map { CGPoint(x: $0, y: staffBottom - 1) }

                for event in beatEvents {
                    drawNote(
                        atX: eventXPosition(
                            event,
                            measureIndex: measureIndex,
                            slotsPerMeasure: slotsPerMeasure,
                            measureWidth: measureWidth
                        ) - viewportOffset,
                        voice: event.voice,
                        color: noteColor(for: event),
                        staffTop: staffTop,
                        staffSpacing: staffSpacing,
                        context: &context
                    )
                }

                drawBeams(
                    notePoints: notePoints,
                    beamCount: pattern.subdivision == .sixteenths ? 2 : 1,
                    context: &context
                )

                if pattern.subdivision == .triplets, notePoints.count > 1,
                   let first = notePoints.first, let last = notePoints.last {
                    let centerX = (first.x + last.x) / 2
                    drawLabel("3", at: CGPoint(x: centerX, y: 38), font: .caption2.bold(), color: .secondary, anchor: .center, context: &context)
                }
            }
        }

        if let playheadX {
            let x = playheadX - viewportOffset
            strokeLine(
                from: CGPoint(x: x, y: 15),
                to: CGPoint(x: x, y: 153),
                color: .accentColor.opacity(0.9),
                width: 2,
                context: &context
            )
            let triangle = Path { path in
                path.move(to: CGPoint(x: x - 6, y: 14))
                path.addLine(to: CGPoint(x: x + 6, y: 14))
                path.addLine(to: CGPoint(x: x, y: 23))
                path.closeSubpath()
            }
            context.fill(triangle, with: .color(.accentColor))
        }

        drawLabel(
            usesMultipleVoices
                ? "Cymbal × · snare center · kick low · rests gray · follow the blue playhead"
                : "Bass drum · rests are gray · follow the blue playhead",
            at: CGPoint(x: 14, y: 186),
            font: .caption,
            color: .secondary,
            anchor: .leading,
            context: &context
        )
    }

    private func drawNote(
        atX x: Double,
        voice: DrumVoice,
        color: Color,
        staffTop: Double,
        staffSpacing: Double,
        context: inout GraphicsContext
    ) {
        let y = noteY(for: voice, staffTop: staffTop, staffSpacing: staffSpacing)
        if isCymbal(voice) {
            strokeLine(
                from: CGPoint(x: x - 6, y: y - 5),
                to: CGPoint(x: x + 6, y: y + 5),
                color: color,
                width: 2,
                context: &context
            )
            strokeLine(
                from: CGPoint(x: x - 6, y: y + 5),
                to: CGPoint(x: x + 6, y: y - 5),
                color: color,
                width: 2,
                context: &context
            )
        } else {
            let head = Path(ellipseIn: CGRect(x: x - 7, y: y - 4, width: 14, height: 8))
            context.fill(head, with: .color(color))
        }
        strokeLine(
            from: CGPoint(x: x + 6, y: y),
            to: CGPoint(x: x + 6, y: 43),
            color: color,
            width: 1.6,
            context: &context
        )
    }

    private func noteY(for voice: DrumVoice, staffTop: Double, staffSpacing: Double) -> Double {
        switch voice {
        case .kick: staffTop + staffSpacing * 4.4
        case .snare, .crossStick: staffTop + staffSpacing * 2
        case .lowTom: staffTop + staffSpacing * 3
        case .midTom: staffTop + staffSpacing * 2
        case .highTom: staffTop + staffSpacing
        case .closedHiHat, .openHiHat, .pedalHiHat, .ride, .rideBell,
             .crash1, .crash2, .china, .splash: staffTop - staffSpacing * 0.8
        case .other, .unknown, .metronome: staffTop + staffSpacing * 2
        }
    }

    private func isCymbal(_ voice: DrumVoice) -> Bool {
        switch voice {
        case .closedHiHat, .openHiHat, .pedalHiHat, .ride, .rideBell,
             .crash1, .crash2, .china, .splash: true
        default: false
        }
    }

    private func drawRest(at point: CGPoint, context: inout GraphicsContext) {
        let rect = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
        context.fill(Path(rect), with: .color(.secondary.opacity(0.32)))
    }

    private func drawBeams(notePoints: [CGPoint], beamCount: Int, context: inout GraphicsContext) {
        guard let first = notePoints.first, let last = notePoints.last else { return }
        if notePoints.count == 1 {
            for beam in 0..<beamCount {
                strokeLine(
                    from: CGPoint(x: first.x + 6, y: 48 + Double(beam) * 5),
                    to: CGPoint(x: first.x + 16, y: 53 + Double(beam) * 5),
                    color: .primary.opacity(0.82),
                    width: 2.2,
                    context: &context
                )
            }
            return
        }

        for beam in 0..<beamCount {
            strokeLine(
                from: CGPoint(x: first.x + 6, y: 48 + Double(beam) * 5),
                to: CGPoint(x: last.x + 6, y: 48 + Double(beam) * 5),
                color: .primary.opacity(0.82),
                width: 3,
                context: &context
            )
        }
    }

    private func drawPercussionClef(atX x: Double, staffTop: Double, context: inout GraphicsContext) {
        strokeLine(from: CGPoint(x: x, y: staffTop + 7), to: CGPoint(x: x, y: staffTop + 33), color: .primary.opacity(0.8), width: 2, context: &context)
        strokeLine(from: CGPoint(x: x + 5, y: staffTop + 7), to: CGPoint(x: x + 5, y: staffTop + 33), color: .primary.opacity(0.8), width: 2, context: &context)
    }

    private func drawTimeSignature(
        numerator: Int,
        denominator: Int,
        atX x: Double,
        staffTop: Double,
        context: inout GraphicsContext
    ) {
        drawLabel("\(numerator)", at: CGPoint(x: x, y: staffTop + 9), font: .headline.bold(), color: .primary, anchor: .center, context: &context)
        drawLabel("\(denominator)", at: CGPoint(x: x, y: staffTop + 29), font: .headline.bold(), color: .primary, anchor: .center, context: &context)
    }

    private func drawLabel(
        _ value: String,
        at point: CGPoint,
        font: Font,
        color: Color,
        anchor: UnitPoint,
        context: inout GraphicsContext
    ) {
        context.draw(Text(value).font(font).foregroundStyle(color), at: point, anchor: anchor)
    }

    private func strokeLine(
        from start: CGPoint,
        to end: CGPoint,
        color: Color,
        width: Double,
        context: inout GraphicsContext
    ) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        context.stroke(path, with: .color(color), lineWidth: width)
    }

    private func xPosition(
        measure: Int,
        slot: Int,
        slotsPerMeasure: Int,
        measureWidth: Double
    ) -> Double {
        PracticeScoreTimeline.notePosition(
            measure: measure,
            slot: Double(slot),
            slotsPerMeasure: slotsPerMeasure,
            measureWidth: measureWidth
        )
    }

    private func scorePosition(
        for current: Int64?,
        start: Int64?,
        end: Int64?,
        measureWidth: Double,
        measureCount: Int
    ) -> Double? {
        guard let current, let start, let end, end > start else { return nil }
        if let offsets = pattern.measureStartOffsetsNanoseconds,
           offsets.count == measureCount + 1 {
            let elapsed = min(max(current - start, 0), end - start)
            let measure = min(
                offsets.lastIndex(where: { $0 <= elapsed }) ?? 0,
                measureCount - 1
            )
            let measureStart = offsets[measure]
            let measureEnd = offsets[measure + 1]
            let progress = measureEnd > measureStart
                ? Double(elapsed - measureStart) / Double(measureEnd - measureStart)
                : 0
            let signature = pattern.signature(forMeasure: measure + 1)
            let slots = pattern.subdivision.notesPerBeat * signature.numerator
            return PracticeScoreTimeline.notePosition(
                measure: measure,
                slot: min(max(progress, 0), 1) * Double(slots),
                slotsPerMeasure: slots,
                measureWidth: measureWidth
            )
        }
        return PracticeScoreTimeline.playheadPosition(
            current: current,
            start: start,
            end: end,
            slotsPerMeasure: pattern.subdivision.notesPerBeat * pattern.beatsPerMeasure,
            measureCount: measureCount,
            measureWidth: measureWidth
        )
    }

    private func viewportOffset(playheadX: Double?, contentWidth: Double, viewportWidth: Double) -> Double {
        guard let playheadX, contentWidth > viewportWidth else { return 0 }
        return min(max(playheadX - viewportWidth * 0.3, 0), contentWidth - viewportWidth)
    }

    private func expectedEvents(measure: Int, beat: Int, subdivision: Int) -> [ExpectedEvent] {
        pattern.expectedEvents.filter {
            $0.measure == measure && $0.beat == beat && $0.subdivision == subdivision
        }
    }

    private var usesContinuousTiming: Bool {
        pattern.measureStartOffsetsNanoseconds?.count == pattern.measures + 1
    }

    private func eventXPosition(
        _ event: ExpectedEvent,
        measureIndex: Int,
        slotsPerMeasure: Int,
        measureWidth: Double
    ) -> Double {
        if let offsets = pattern.measureStartOffsetsNanoseconds,
           offsets.count == pattern.measures + 1,
           offsets.indices.contains(measureIndex + 1) {
            let measureStart = offsets[measureIndex]
            let measureEnd = offsets[measureIndex + 1]
            let eventOffset = event.sessionTimeNanoseconds - pattern.startSessionTimeNanoseconds
            if measureEnd > measureStart {
                let progress = min(
                    max(Double(eventOffset - measureStart) / Double(measureEnd - measureStart), 0),
                    0.999_999
                )
                return PracticeScoreTimeline.notePosition(
                    measure: measureIndex,
                    slot: progress * Double(slotsPerMeasure),
                    slotsPerMeasure: slotsPerMeasure,
                    measureWidth: measureWidth
                )
            }
        }
        let slot = (event.beat - 1) * pattern.subdivision.notesPerBeat + event.subdivision
        return xPosition(
            measure: measureIndex,
            slot: slot,
            slotsPerMeasure: slotsPerMeasure,
            measureWidth: measureWidth
        )
    }

    private func uniqueNoteXPositions(_ positions: [Double]) -> [Double] {
        positions.sorted().reduce(into: []) { result, position in
            if result.last.map({ abs($0 - position) > 0.5 }) ?? true {
                result.append(position)
            }
        }
    }

    private func noteColor(for event: ExpectedEvent) -> Color {
        switch classifications[event.id] {
        case .correct: .green
        case .missed: .orange
        case .wrongVoice: .red
        case .ambiguous: .purple
        case .extra: .purple
        case nil: .primary
        }
    }

    private func countLabel(beat: Int, subdivision: Int) -> String {
        switch pattern.subdivision {
        case .eighths:
            subdivision == 0 ? "\(beat + 1)" : "&"
        case .sixteenths:
            ["\(beat + 1)", "e", "&", "a"][subdivision]
        case .triplets:
            ["\(beat + 1)", "trip", "let"][subdivision]
        }
    }

    private var accessibilityDescription: String {
        "\(hitsPerMeasure) limb hits per measure for \(pattern.measures) measures."
    }

    private var usesMultipleVoices: Bool {
        Set(pattern.expectedEvents.map(\.voice)).count > 1
    }

    private var hitsPerMeasure: Int {
        pattern.expectedEvents.count { $0.measure == 1 }
    }
}

enum PracticeScoreTimeline {
    static func notePosition(
        measure: Int,
        slot: Double,
        slotsPerMeasure: Int,
        measureWidth: Double
    ) -> Double {
        let measureLeft = 48 + Double(measure) * measureWidth
        let musicalStart = measureLeft + 66
        let musicalWidth = measureWidth - 84
        return musicalStart + (slot + 0.35) / Double(slotsPerMeasure) * musicalWidth
    }

    static func playheadPosition(
        current: Int64,
        start: Int64,
        end: Int64,
        slotsPerMeasure: Int,
        measureCount: Int,
        measureWidth: Double
    ) -> Double? {
        guard end > start, slotsPerMeasure > 0, measureCount > 0 else { return nil }
        let progress = min(max(Double(current - start) / Double(end - start), 0), 1)
        let totalSlots = slotsPerMeasure * measureCount
        let elapsedSlots = progress * Double(totalSlots)
        let measure: Int
        let slotInMeasure: Double
        if progress >= 1 {
            measure = measureCount - 1
            slotInMeasure = Double(slotsPerMeasure)
        } else {
            measure = min(Int(elapsedSlots / Double(slotsPerMeasure)), measureCount - 1)
            slotInMeasure = elapsedSlots - Double(measure * slotsPerMeasure)
        }
        return notePosition(
            measure: measure,
            slot: slotInMeasure,
            slotsPerMeasure: slotsPerMeasure,
            measureWidth: measureWidth
        )
    }
}
