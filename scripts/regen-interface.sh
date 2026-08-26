#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
TBD="$SDK_PATH/System/Library/PrivateFrameworks/SiriTTSService.framework/SiriTTSService.tbd"
INTERFACE="$PROJECT_DIR/Sources/PrivateInterfaces/SiriTTSService.swiftmodule/arm64-apple-macos.swiftinterface"

if [[ ! -f "$TBD" ]]; then
  print -u2 "regen-interface: SiriTTSService.tbd is absent from this SDK"
  exit 1
fi

REQUIRED=(
  'DaemonSessionC06invokeC0'
  'DaemonSessionC10synthesize'
  'DaemonSessionC16downloadedVoices'
  'DaemonSessionC7prewarm'
  'DaemonSessionC6cancel'
  'DaemonSessionC22queryWordTimingSupport'
  'DaemonSessionC10keepActive'
  'DaemonSessionC16predefinedVoices'
  'DaemonSessionC9subscribe'
  'DaemonSessionC18isANEModelCompiled'
  'SynthesisVoiceC8assetKey'
  'AudioDataC11sampleCount'
  'WordTimingInfoC9startTime'
  'SynthesisContextC16didGenerateAudio'
  'SynthesisContextC22didGenerateWordTimings'
)

for SYMBOL in "${REQUIRED[@]}"; do
  if ! grep -q "$SYMBOL" "$TBD"; then
    print -u2 "regen-interface: required ABI symbol is missing: $SYMBOL"
    exit 1
  fi
done

TEMP="$(mktemp "${TMPDIR:-/tmp}/siri-interface.XXXXXX")"
trap 'rm -f "$TEMP"' EXIT
sed \
  "s|// swift-compiler-version:.*|// swift-compiler-version: $(swift --version | head -1)|" \
  "$INTERFACE" > "$TEMP"
mv "$TEMP" "$INTERFACE"

print "Verified the reconstructed SiriTTSService ABI and refreshed its compiler header:"
print "  $INTERFACE"
print "SDK: $SDK_PATH"
