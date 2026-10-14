#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp /private/tmp/DrumTrainer-midi-fixtures.XXXXXX)
trap 'rm -f "$binary"' EXIT
swiftc -module-cache-path /private/tmp/DrumTrainer-native-fixture-modules \
  DrumTrainer/Domain/Models/DrumVoice.swift DrumTrainer/Domain/Models/EventSource.swift \
  DrumTrainer/Domain/Models/PracticeModels.swift DrumTrainer/Domain/Models/ImportedSong.swift \
  DrumTrainer/Services/Timing/HostTimeConverter.swift DrumTrainer/Services/MIDI/StandardMIDIFileParser.swift \
  DrumTrainer/Domain/Patterns/ImportedSongPatternGenerator.swift Windows/validation/GenerateMIDIFixtures.swift -o "$binary"
"$binary" Windows/validation/native-midi-fixtures.json
