#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SIRI_TTS_BIN="${SIRI_TTS_BIN:-$PROJECT_DIR/build/siri-tts}"
ITERATIONS="${ITERATIONS:-5}"
BENCH_DIR="$(mktemp -d "${TMPDIR:-/tmp}/siri-tts-benchmark.XXXXXX")"
trap 'rm -rf "$BENCH_DIR"' EXIT

if [[ ! -x "$SIRI_TTS_BIN" ]]; then
  print -u2 "benchmark: binary not found: $SIRI_TTS_BIN"
  exit 1
fi

VOICE="$("$SIRI_TTS_BIN" voices --json | plutil -extract voices.0.name raw -o - -)"
print "mode,iteration,time_to_first_audio_seconds,time_to_complete_seconds,audio_duration_seconds"

for MODE in prewarm no-prewarm; do
  for ITERATION in {1..$ITERATIONS}; do
    EXTRA=()
    if [[ "$MODE" == "no-prewarm" ]]; then
      EXTRA=(--no-prewarm)
    fi
    RESULT="$BENCH_DIR/${MODE}-${ITERATION}.json"
    "$SIRI_TTS_BIN" synthesize \
      --voice "$VOICE" \
      --json \
      "${EXTRA[@]}" \
      -o "$BENCH_DIR/${MODE}-${ITERATION}.wav" \
      "Benchmark run ${MODE} ${ITERATION} ${RANDOM}." > "$RESULT"
    FIRST="$(plutil -extract timeToFirstAudioSeconds raw -o - "$RESULT" 2>/dev/null || print unavailable)"
    COMPLETE="$(plutil -extract elapsedSeconds raw -o - "$RESULT")"
    DURATION="$(plutil -extract audio.durationSeconds raw -o - "$RESULT")"
    print "${MODE},${ITERATION},${FIRST},${COMPLETE},${DURATION}"
  done
done
