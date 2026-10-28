#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuGraphReuseState.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
root="Sources/OngakuDesktop"
effect_sources=("$root/AudioEffectPreset.swift" "$root/EffectTransitionPolicy.swift"
 "$root/AudioEffectNode.swift" "$root/AudioEffectModuleRegistry.swift" "$root/"*AudioEffect.swift)
unit_root="Sources/OngakuAudioDSP"; header_root="$unit_root/include"
for unit in GainEnvelope TruePeak SpectralTransient; do
 xcrun clang++ -std=c++20 -O2 -fobjc-arc -fblocks -I "$header_root" -c "$unit_root/${unit}AudioUnit.mm" -o "$audit_dir/$unit.o"
done
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$audit_dir/cache" \
 -import-objc-header "$header_root/TruePeakAudioUnit.h" "${effect_sources[@]}" \
 "$root/AudioProcessingPolicy.swift" "$root/AudioThreadGainStage.swift" Tests/AudioDSP/EffectAuditSupport.swift \
 Tests/AudioDSP/GraphReuseStateRegression.swift "$audit_dir/"*.o -Xlinker -lc++ -o "$audit_dir/reuse"
"$audit_dir/reuse"
if "$audit_dir/reuse" --skip-reset > "$audit_dir/negative.log" 2>&1; then
 echo 'FAIL: retained-history negative control escaped detection'; exit 1
fi
grep -Fq 'retired track history survived graph reuse' "$audit_dir/negative.log" || { cat "$audit_dir/negative.log"; exit 1; }
echo 'PASS: rejected missing full-state reset negative control'
