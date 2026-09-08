#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SAY2_BIN="${SAY2_BIN:-$PROJECT_DIR/build/say2}"
SMOKE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/say2-smoke.XXXXXX")"
trap 'rm -rf "$SMOKE_DIR"' EXIT

if [[ ! -x "$SAY2_BIN" ]]; then
  print -u2 "smoke: binary not found: $SAY2_BIN"
  exit 1
fi

"$SAY2_BIN" --version
"$SAY2_BIN" voices --json > "$SMOKE_DIR/voices.json"
VOICE="$(plutil -extract voices.0.name raw -o - "$SMOKE_DIR/voices.json")"
if [[ -z "$VOICE" ]]; then
  print -u2 "smoke: no installed Siri voices"
  exit 1
fi

TEXT="Siri Voice smoke test ${RANDOM} ${RANDOM}."
"$SAY2_BIN" synthesize \
  --voice "$VOICE" \
  --timings "$SMOKE_DIR/timings.json" \
  --json \
  -o "$SMOKE_DIR/output.wav" \
  "$TEXT" > "$SMOKE_DIR/result.json"

afinfo "$SMOKE_DIR/output.wav" > "$SMOKE_DIR/afinfo.txt"
grep -q "audio bytes:" "$SMOKE_DIR/afinfo.txt"
grep -q "source bit depth: I16" "$SMOKE_DIR/afinfo.txt"

DURATION="$(plutil -extract audio.durationSeconds raw -o - "$SMOKE_DIR/result.json")"
NON_SILENT="$(plutil -extract audio.nonSilent raw -o - "$SMOKE_DIR/result.json")"
TIMING_COUNT="$(plutil -extract timings json -o - "$SMOKE_DIR/timings.json" | awk '{ count += gsub(/utf16Location/, "&") } END { print count + 0 }')"
if (( $(awk "BEGIN { print ($DURATION <= 0.05) }") )) || [[ "$NON_SILENT" != "true" ]]; then
  print -u2 "smoke: audio acceptance failed"
  exit 1
fi

"$SAY2_BIN" doctor --skip-probe --json > "$SMOKE_DIR/doctor.json"
plutil -extract daemonReachable raw -o - "$SMOKE_DIR/doctor.json" | grep -q true

print "smoke: passed"
print "  voice: $VOICE"
print "  duration: ${DURATION}s"
print "  timings: $TIMING_COUNT"
