"""Expose the actual native private buffer builders in a temporary copy, without changing Mac source."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
source = (root / 'DrumTrainer/Services/Metronome/MetronomeEngine.swift').read_text()
extension = r'''
struct SynthFixture: Encodable {
    var kind: String; var sound: String; var sampleRate: Double; var gainDB: Double
    var accent: Bool; var dynamics: Double; var frameCount: Int; var indexes: [Int]; var samples: [Float]
}
extension MetronomeEngine {
    static func soundFixtures() -> [SynthFixture] {
        var result: [SynthFixture] = []
        func append(_ kind: String, _ sound: String, _ rate: Double, _ gain: Double, _ accent: Bool, _ dynamics: Double, _ buffer: AVAudioPCMBuffer) {
            let count = Int(buffer.frameLength)
            let indexes = Array(Set((0..<128).map { Int(Double($0) / 127 * Double(count - 1)) } + [0,1,2,3,4,10,20,50,100])).sorted()
            let samples = indexes.map { buffer.floatChannelData![0][$0] }
            result.append(SynthFixture(kind: kind, sound: sound, sampleRate: rate, gainDB: gain, accent: accent, dynamics: dynamics, frameCount: count, indexes: indexes, samples: samples))
        }
        for rate in [44100.0,48000.0] {
            let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
            for sound in MetronomeSound.allCases {
                for gain in [-3.0,12.0] {
                    for accent in [false,true] {
                        append("click",sound.rawValue,rate,gain,accent,1,makeClick(format: format,sound: sound,isAccent: accent,gainDecibels: gain)!)
                    }
                }
            }
            for sound in KickMonitorSound.allCases {
                for gain in [-6.0,6.0] {
                    for dynamics in [0.2,1.0] {
                        append("kick",sound.rawValue,rate,gain,false,dynamics,makeKick(format: format,sound: sound,gainDecibels: gain,dynamicsGain: dynamics)!)
                    }
                }
            }
        }
        return result
    }
}
@main struct ExportSounds {
    static func main() throws {
        let fixtures = MetronomeEngine.soundFixtures()
        let data = try JSONEncoder().encode(fixtures)
        try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
        print("Generated \(fixtures.count) native synthesized-sound reference cases.")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='DrumTrainer-sound-fixtures-') as temp:
    path = Path(temp)
    swift = path / 'NativeMetronomeFixtures.swift'
    swift.write_text(source + extension)
    support = path / 'SoundFixtureSupport.swift'
    support.write_text('enum MusicalTarget { case drum(DrumVoice) }\n')
    binary = path / 'export-sounds'
    subprocess.run(['swiftc', '-module-cache-path', '/private/tmp/DrumTrainer-native-fixture-modules',
                    str(root / 'DrumTrainer/Domain/Models/EventSource.swift'),
                    str(root / 'DrumTrainer/Domain/Models/DrumVoice.swift'),
                    str(root / 'DrumTrainer/Domain/Models/PracticeModels.swift'),
                    str(support),
                    str(root / 'DrumTrainer/Services/Timing/ClockProviding.swift'),
                    str(root / 'DrumTrainer/Services/Timing/HostTimeConverter.swift'),
                    str(swift), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root / 'Windows/validation/native-sound-fixtures.json')], check=True)
