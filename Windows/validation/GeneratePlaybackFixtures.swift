import Foundation
struct Step: Codable { var type: String = "frame"; var level: Double?; var time: Double?; var duration: Double? }
struct Result: Codable { var ready: Bool; var triggered: Bool; var onset: Double? }
struct Fixture: Codable { var name: String; var threshold: Double?; var steps: [Step]; var results: [Result] }
@main struct GeneratePlaybackFixtures {
    static func main() throws {
        func frames(_ level: Double, _ count: Int, start: Double = 0, duration: Double = 0.005) -> [Step] { (0..<count).map { Step(level: level, time: start + Double($0) * duration, duration: duration) } }
        let quiet = frames(-80, 60)
        let cases: [(String, Double?, [Step])] = [
            ("quiet then sustained playback", -45, quiet + frames(-20, 8, start: 0.3)),
            ("playing before arming never readies", -45, frames(-20, 100)),
            ("less than 300 ms quiet", -45, frames(-80, 59) + frames(-20, 10, start: 0.295)),
            ("short burst resets candidate", -45, quiet + frames(-20, 2, start: 0.3) + frames(-80, 1, start: 0.31) + frames(-20, 4, start: 0.315)),
            ("threshold equality counts as loud", -45, quiet + frames(-45, 4, start: 0.3)),
            ("capture gap resets readiness", -45, quiet + frames(-20, 8, start: 0.8)),
            ("250 ms gap stays ready", -45, quiet + frames(-20, 8, start: 0.55)),
            ("out of order frame rejected", -45, quiet + [Step(level: -20, time: 0.1, duration: 0.02)] + frames(-20, 4, start: 0.3)),
            ("silent stream observation readies", -45, [Step(type: "silent")] + frames(-20, 8, start: 0.8)),
            ("invalid frame values ignored", -45, quiet + [Step(level: nil, time: 0.3, duration: 0.02), Step(level: -20, time: nil, duration: 0.02), Step(level: -20, time: 0.3, duration: 0), Step(level: -20, time: 0.3, duration: 0.100001)] + frames(-20, 4, start: 0.3)),
            ("invalid threshold defaults", nil, quiet + frames(-20, 4, start: 0.3)),
            ("threshold clamps lower", -100, frames(-120, 60) + frames(-70, 4, start: 0.3)),
            ("threshold clamps upper", 0, quiet + frames(-5, 4, start: 0.3))
        ]
        let fixtures = cases.map { name, threshold, steps in
            var detector = PlaybackOnsetDetector(thresholdDBFS: threshold ?? .nan)
            let results = steps.map { step in
                var onset: Double?
                if step.type == "silent" { detector.observeSilentCaptureInterval() }
                else { onset = detector.consume(levelDBFS: step.level ?? .nan, time: step.time ?? .nan, duration: step.duration ?? .nan) }
                return Result(ready: detector.isReady, triggered: detector.hasTriggered, onset: onset)
            }
            return Fixture(name: name, threshold: threshold, steps: steps, results: results)
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(fixtures).write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("Generated \(fixtures.count) native playback onset fixtures.")
    }
}
