#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
binary=$(mktemp /private/tmp/DrumTrainer-playback-fixtures.XXXXXX)
source=$(mktemp /private/tmp/DrumTrainer-playback-detector.XXXXXX.swift)
trap 'rm -f "$binary" "$source"' EXIT
printf 'import Foundation\n' > "$source"
sed -n '/^struct PlaybackOnsetDetector:/,/^@MainActor/{ /^@MainActor/!p; }' DrumTrainer/Services/Audio/ExternalPlaybackListener.swift >> "$source"
swiftc -module-cache-path /private/tmp/DrumTrainer-native-fixture-modules "$source" Windows/validation/GeneratePlaybackFixtures.swift -o "$binary"
"$binary" Windows/validation/native-playback-fixtures.json
