#!/bin/bash
set -euo pipefail
benchmark_dir=$(cd "$(dirname "$0")" && pwd)
iphone_root=${1:-$(cd "$benchmark_dir/../.." && pwd)}
result_path=${2:-/private/tmp/ongaku-sinc-benchmark.jsonl}
build_dir=$(mktemp -d /private/tmp/OngakuCPUMetal.XXXXXX)
trap 'rm -rf "$build_dir"' EXIT
python3 "$benchmark_dir/extract_fixture.py" "$build_dir/ShippingSinc.swift" "$iphone_root"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$build_dir/cache" \
    "$build_dir/ShippingSinc.swift" "$benchmark_dir/Benchmark.swift" -o "$build_dir/benchmark"
python3 "$benchmark_dir/run_matrix.py" "$build_dir/benchmark" "$benchmark_dir/Sinc.metal" "$result_path"
swiftc -parse-as-library -O -suppress-warnings -module-cache-path "$build_dir/cache" \
    "$build_dir/ShippingSinc.swift" "$benchmark_dir/PolicyProbe.swift" -o "$build_dir/policy"
"$build_dir/policy" > "${result_path%.jsonl}-policy.jsonl"
# A broken shader must fail the numerical gate; compilation alone is insufficient.
sed 's/= result;/= result * 1.001f;/' "$benchmark_dir/Sinc.metal" > "$build_dir/Broken.metal"
if "$build_dir/benchmark" gpu 44100 96000 256 linear master 1 "$build_dir/Broken.metal" > "$build_dir/negative.log" 2>&1; then
    echo 'FAIL: corrupted Metal output escaped detection' >&2
    exit 1
fi
if ! grep -q 'Float64 reference tolerance failed' "$build_dir/negative.log"; then
    cat "$build_dir/negative.log" >&2
    exit 1
fi
echo 'PASS: 58 isolated measurements, shipping throttle probe, corrupted-shader negative control'
