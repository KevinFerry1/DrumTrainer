#!/bin/sh
# Compile the repository's actual Swift drum algorithms, then export non-personal reference cases.
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp /private/tmp/DrumTrainer-native-fixtures.XXXXXX)
trap 'rm -f "$binary"' EXIT
swiftc -module-cache-path /private/tmp/DrumTrainer-native-fixture-modules \
  DrumTrainer/Domain/Models/DrumVoice.swift \
  DrumTrainer/Domain/Models/EventSource.swift \
  DrumTrainer/Domain/Models/EventMetadata.swift \
  DrumTrainer/Domain/Models/PerformanceEvent.swift \
  DrumTrainer/Domain/Models/PracticeModels.swift \
  DrumTrainer/Domain/Patterns/KickPatternGenerator.swift \
  DrumTrainer/Domain/Scoring/EventMatcher.swift \
  DrumTrainer/Domain/Scoring/ScoringMetrics.swift \
  DrumTrainer/Services/Timing/HostTimeConverter.swift \
  DrumTrainer/Services/Audio/KickSoundClassifier.swift \
  Windows/validation/NativeFixtureSupport.swift \
  Windows/validation/GenerateNativeFixtures.swift -o "$binary"
"$binary" Windows/validation/native-fixtures.json
