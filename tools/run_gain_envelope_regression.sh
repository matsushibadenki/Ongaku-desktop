#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuGainEnvelope.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
root="$PWD/Sources/OngakuAudioDSP"
include="$root/include"
sanitizers=()
if [[ "${GAIN_SANITIZERS:-0}" == 1 ]]; then sanitizers=(-fsanitize=address,undefined -fno-omit-frame-pointer); fi
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks ${sanitizers[@]+"${sanitizers[@]}"} \
 -I "$include" -framework AVFoundation -framework AudioToolbox -framework Foundation \
 "$root/GainEnvelopeAudioUnit.mm" Tests/AudioDSP/GainEnvelopeAudioUnitTests.mm -o "$audit_dir/au"
"$audit_dir/au"
xcrun clang++ -std=c++20 -O2 ${sanitizers[@]+"${sanitizers[@]}"} -I "$root" \
 Tests/AudioDSP/GainEnvelopeConcurrency.cpp -o "$audit_dir/concurrency"
"$audit_dir/concurrency"
# Reject a 48-step substitute: the reference checks individual rendered samples.
mkdir "$audit_dir/negative"
cp "$root/GainEnvelopeAudioUnit.mm" "$audit_dir/negative/"
cp "$include/GainEnvelopeAudioUnit.h" "$audit_dir/negative/"
python3 - "$root/GainEnvelopeDSP.hpp" "$audit_dir/negative/GainEnvelopeDSP.hpp" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
old='const double p = double(elapsed) / double(duration);'
assert old in s
Path(sys.argv[2]).write_text(s.replace(old,'const double p = std::floor(double(elapsed) / double(duration) * 48) / 48;'))
PY
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -I "$audit_dir/negative" \
 -framework AVFoundation -framework AudioToolbox -framework Foundation \
 "$audit_dir/negative/GainEnvelopeAudioUnit.mm" Tests/AudioDSP/GainEnvelopeAudioUnitTests.mm -o "$audit_dir/negative/au"
if "$audit_dir/negative/au" > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: control-step substitute accepted'; exit 1
fi
grep -Fq 'sample-aligned cosine residual exceeded' "$audit_dir/negative.log"
echo 'PASS: negative control rejects a 48-step envelope'
