# CPU / Metal Sinc benchmark

Development-only offline harness; it is not linked into either app. Requires a
macOS host with an accessible Metal device, Swift and Python 3. Metal access may
require running outside the development sandbox. No network or media library is
used. Generated audio and build products are temporary.

From the iPhone repository:

```sh
bash tests/sinc-benchmark/run.sh /Users/Shared/Program/Xcode/Ongaku /private/tmp/sinc-run.jsonl
```

The identical Mac copy lives under `tools/sinc-benchmark`; pass the iPhone source
root explicitly. Mac currently uses AVAudioEngine conversion, not this custom
Precision Sinc implementation. This shared harness compares equivalent kernels;
it does not benchmark or replace the entire Mac audio graph.

`extract_fixture.py` extracts shipping CPU methods and kernel generation verbatim,
fails on missing/duplicate method anchors, and adds small measurement adapters.
No production source is rewritten. The GPU uses these exact Float32 coefficients,
CPU-computed Double sample/phase positions, zero padding and 262,144-frame chunks.
Metal fast math is disabled; explicit FMA still permits rounding differences from
Accelerate reduction. Each GPU thread computes one output sample/channel.

`run_matrix.py` runs 29 stereo settings in separate CPU/GPU processes, alternating
backend order. Each process measures its first transform and seven warm transforms.
Warm wall time includes allocations, position planning, source upload, command
submission/waiting and output copying; it excludes common kernel generation and
backend setup, which are reported separately. `warm_p95_ms` is the nearest-rank
maximum of seven observations, not a statistically robust tail-latency estimate.
`gpu_device_median_ms` excludes host overhead and must not be used alone as speedup.

Memory: Darwin peak RSS is measured before validation/reference allocations.
Physical footprint is a **post-measurement snapshot**, not a measured peak.
Metal `currentAllocatedSize` is sampled while a dispatch's buffers are alive;
it is not total GPU/driver usage. These counters overlap: never add them together.
Both benchmarks retain the whole generated source and output, unlike production
streaming source windows. No full-track memory saving can be inferred.

Accuracy: all output samples must be finite. All GPU output samples are compared
with shipping CPU output. An independent Float64 dot product of the quantized
coefficients checks about 4,096 positions/channel plus edges, signal transitions
and a chunk boundary. Gates: maximum error < 2e-6 FS and reference SNR > 110 dB.
The fixture includes silence/impulses, DC, 997 Hz, near-Nyquist tone, chirp and
deterministic noise, with distinct channels. This is numerical equivalence testing,
not a new spectral-response certification or evidence of audible improvement.

`PolicyProbe.swift` additionally measures the shipping file reader plus deliberate
CPU throttling for 3-second fixtures. These measurements are separate from the
unthrottled CPU/GPU comparison; GPU has no equivalent thermal-duty policy here.
A shader deliberately scaling output by 1.001 must fail the accuracy gate. Its
expected error exit may appear as a Swift `Trace/BPT trap` in the runner log.

Raw evidence and decisions are in `docs/CPU_METAL_UPSAMPLING_VALIDATION.md`.
Re-run on each target device before choosing any production GPU backend. The
prototype checks cancellation between submissions and after completion; an
already submitted command cannot be preempted by that check. Cancellation races,
allocation failure fallback and audio-render integration are not production-ready.
