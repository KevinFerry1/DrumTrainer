#!/bin/sh
# Compile the repository's actual Swift drum algorithms, then export non-personal reference cases.
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp /private/tmp/DrumTrainer-native-fixtures.XXXXXX)
timeline=$(mktemp /private/tmp/DrumTrainer-native-timeline.XXXXXX.swift)
scoretimeline=$(mktemp /private/tmp/DrumTrainer-native-score-timeline.XXXXXX.swift)
trap 'rm -f "$binary" "$timeline" "$scoretimeline"' EXIT
printf 'import Foundation\n' > "$timeline"
sed -n '/^struct PracticeTimingTimelineEntry:/,/^struct SavedCustomExercise:/{ /^struct SavedCustomExercise:/!p; }' DrumTrainer/Domain/Scoring/PracticeSessionRecording.swift >> "$timeline"
printf 'import Foundation\n' > "$scoretimeline"
sed -n '/^enum PracticeScoreTimeline/,$p' DrumTrainer/Features/Practice/PracticeScoreView.swift >> "$scoretimeline"
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
  "$timeline" "$scoretimeline" \
  Windows/validation/NativeFixtureSupport.swift \
  Windows/validation/GenerateNativeFixtures.swift -o "$binary"
"$binary" Windows/validation/native-fixtures.json
