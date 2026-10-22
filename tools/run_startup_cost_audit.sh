#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${1:?Pass a dedicated output/scratch directory}"
out="$1"
mkdir -p "$out"
configs=(ordinary gain gain-truepeak)
for config in "${configs[@]}"; do
 flags=(-Xswiftc -DONGAKU_STARTUP_AUDIT -Xswiftc -enable-testing)
 if [[ "$config" != ordinary ]]; then flags+=(-Xswiftc -DONGAKU_ENABLE_AUDIO_THREAD_GAIN); fi
 if [[ "$config" == gain-truepeak ]]; then flags+=(-Xswiftc -DONGAKU_ENABLE_TRUE_PEAK); fi
 env -u ONGAKU_STARTUP_REPORT swift test --build-system native -c release --scratch-path "$out/build-$config" "${flags[@]}" --filter StartupCostAuditTests > "$out/build-$config.log" 2>&1
done
for round in 0 1 2; do
 for offset in 0 1 2; do
  config="${configs[$(((round+offset)%3))]}"
  flags=(-Xswiftc -DONGAKU_STARTUP_AUDIT -Xswiftc -enable-testing)
  if [[ "$config" != ordinary ]]; then flags+=(-Xswiftc -DONGAKU_ENABLE_AUDIO_THREAD_GAIN); fi
  if [[ "$config" == gain-truepeak ]]; then flags+=(-Xswiftc -DONGAKU_ENABLE_TRUE_PEAK); fi
  ONGAKU_STARTUP_REPORT="$out/mac-$config-$round.json" swift test --build-system native -c release --skip-build --scratch-path "$out/build-$config" "${flags[@]}" --filter StartupCostAuditTests > "$out/mac-$config-$round.log" 2>&1
  test -s "$out/mac-$config-$round.json"
 done
done
