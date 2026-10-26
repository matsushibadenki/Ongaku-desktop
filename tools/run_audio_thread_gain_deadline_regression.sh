#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuGainDeadline.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
root=Sources/OngakuDesktop
unit_root=Sources/OngakuAudioDSP
include="$unit_root/include"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -I "$include" -c "$unit_root/GainEnvelopeAudioUnit.mm" -o "$audit_dir/gain.o"
compile() {
 swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$audit_dir/cache" \
  -import-objc-header "$include/GainEnvelopeAudioUnit.h" "$1" Tests/AudioDSP/AudioThreadGainDeadlineRegression.swift \
  "$audit_dir/gain.o" -Xlinker -lc++ -o "$2"
}
compile "$root/AudioThreadGainStage.swift" "$audit_dir/deadline"
"$audit_dir/deadline"
python3 - "$root/AudioThreadGainStage.swift" "$audit_dir/without-deadline.swift" <<'PY'
import sys
s=open(sys.argv[1]).read()
old='guard token != 0, now() < deadline else {'
assert s.count(old)==1
open(sys.argv[2],'w').write(s.replace(old,'guard token != 0 else {'))
PY
compile "$audit_dir/without-deadline.swift" "$audit_dir/negative"
if "$audit_dir/negative" > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: missing deadline escaped detection'; exit 1
fi
grep -Fq 'elapsed deadline did not stop I/O before commit' "$audit_dir/negative.log"
echo 'PASS: rejected missing-deadline negative control'
