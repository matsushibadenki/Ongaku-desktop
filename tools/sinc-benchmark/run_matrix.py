"""Separate processes keep CPU/GPU peak RSS independent. Alternating order limits bias."""
import json
from pathlib import Path
import subprocess
import sys

binary, shader, destination = sys.argv[1:]
cases = [(rate, target, rate * 3, phase, quality)
         for rate, target in [(44100, 96000), (48000, 96000), (44100, 192000)]
         for phase in ['linear', 'minimumPhase', 'apodizing']
         for quality in ['eco', 'standard', 'master']]
cases += [(44100, 96000, frames, 'linear', 'master') for frames in [256, 441000]]
with Path(destination).open('w') as out:
    for number, case in enumerate(cases):
        for backend in (['cpu', 'gpu'] if number % 2 == 0 else ['gpu', 'cpu']):
            result = subprocess.run([binary, backend, *map(str, case), '7', shader], text=True, capture_output=True)
            if result.returncode:
                raise RuntimeError(f'{backend} {case}: {result.stderr}')
            row = json.loads(result.stdout)
            out.write(json.dumps(row, sort_keys=True) + '\n'); out.flush()
            print(f'{number+1}/{len(cases)} {backend} {case}: {row["warm_median_ms"]:.3f} ms, RSS {row["peak_rss_bytes"]/1048576:.2f} MiB', flush=True)
