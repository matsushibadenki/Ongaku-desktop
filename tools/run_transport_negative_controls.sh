#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
audit_dir=$(mktemp -d /private/tmp/OngakuMacTransport.XXXXXX)
trap 'rm -rf "$audit_dir"' EXIT
python3 - "$audit_dir" <<'PY'
from pathlib import Path
import sys
root=Path(sys.argv[1]); source=Path('Sources/OngakuDesktop/TransportOutputEnvelope.swift').read_text()
(root/'original.swift').write_text(source)
(root/'early.swift').write_text(source.replace('guard running else { finishStop(token); return }','finishStop(token); return'))
(root/'stale.swift').write_text(source.replace('        stopped = completion\n        guard !isStopping else { return }','        guard !isStopping else { return }\n        stopped = completion'))
PY
cat > "$audit_dir/main.swift" <<'SWIFT'
import Foundation
@MainActor final class Clock {
    var now = 0.0
    var events: [(Double, @MainActor () -> Void)] = []
    func schedule(_ delay: Double, _ action: @escaping @MainActor () -> Void) { events.append((now + delay, action)) }
    func advance(_ target: Double) {
        while let next = events.enumerated().filter({ $0.element.0 <= target }).min(by: { $0.element.0 < $1.element.0 }) {
            let event = events.remove(at: next.offset); now = event.0; event.1()
        }
        now = target
    }
}
@main struct Audit {
    @MainActor static func main() {
        let clock = Clock(); var completion = 0
        let ramp = TransportOutputEnvelope(schedule: clock.schedule) { _ in }
        ramp.start(ready: { true }, failed: {})
        clock.advance(0.03)
        ramp.stop(running: true, drain: 0.012) { completion = 1 }
        if completion != 0 { print("FAIL: teardown before fade/drain"); exit(1) }
        ramp.stop(running: true, drain: 0.012) { completion = 2 }
        clock.advance(0.0541)
        if completion != 0 || ramp.gain != 0 { print("FAIL: teardown before drain"); exit(1) }
        clock.advance(0.067)
        if completion != 2 { print("FAIL: stale completion replaced newest intent"); exit(1) }
        print("PASS: transport source retention and latest-request ownership")
    }
}
SWIFT
for variant in original early stale; do
 swiftc -parse-as-library -module-cache-path "$audit_dir/cache" \
  Tests/AudioDSP/EffectAuditSupport.swift Sources/OngakuDesktop/AudioEffectPreset.swift \
  Sources/OngakuDesktop/EffectTransitionPolicy.swift "$audit_dir/$variant.swift" "$audit_dir/main.swift" -o "$audit_dir/$variant"
 if [[ "$variant" == original ]]; then "$audit_dir/$variant"
 else
  if "$audit_dir/$variant" > "$audit_dir/$variant.log" 2>&1; then echo "FAIL: $variant mutation accepted"; exit 1; fi
  if [[ "$variant" == early ]]; then grep -Fq 'teardown before fade/drain' "$audit_dir/$variant.log"
  else grep -Fq 'stale completion replaced newest intent' "$audit_dir/$variant.log"; fi
  echo "PASS: rejects $variant transport mutation"
 fi
done
