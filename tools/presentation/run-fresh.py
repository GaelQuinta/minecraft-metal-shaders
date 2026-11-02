# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
"""Run fixed-setting A/B/B/A sessions; each uses a disposable world and exits itself."""
import argparse
import json
from pathlib import Path
import subprocess
import sys

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('jar', type=Path)
p.add_argument('--java-home', type=Path, required=True)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--fullscreen', action='store_true')
p.add_argument('--sdr', action='store_true')
p.add_argument('--schedule-ms', type=float, default=0, help='Compare deadline scheduling instead of fresh-frame selection')
p.add_argument('--phases', default='50,60,120,120g')
p.add_argument('--sample-ms', type=int, default=10000)
p.add_argument('--load-scale', type=float, default=1.0)
p.add_argument('--load-step-ms', type=int, default=237)
p.add_argument('--output-height', type=int)
p.add_argument('--control-jar', type=Path, help='Baseline control jar for sessions 0 and 3')
p.add_argument('--adaptive-pacing', action='store_true', help='Enable GPU-readiness adaptive pacing in candidate sessions')
p.add_argument('--adaptive-safety-margin-ms', type=float, default=1.5, help='Safety margin in ms for adaptive pacing')
p.add_argument('--adaptive-window-size', type=int, default=8, help='Window size for GPU duration estimator')
p.add_argument('--telemetry', action='store_true', help='Record high-precision in-memory telemetry')
a = p.parse_args()
if not 0 <= a.schedule_ms <= 50:
    p.error('Use a schedule of 0–50 ms')
a.output = a.output.resolve()
a.output.mkdir(parents=True, exist_ok=False)
here = Path(__file__).resolve().parent
for i, enabled in enumerate([False, True, True, False]):
    if enabled:
        mode = 'adaptive' if a.adaptive_pacing else ('schedule' if a.schedule_ms else 'fresh')
        current_jar = a.jar.resolve()
    else:
        mode = 'baseline'
        current_jar = a.control_jar.resolve() if a.control_jar else a.jar.resolve()
    output = a.output / f'{i}-{mode}'
    command = [sys.executable, here / 'fresh-bench.py', current_jar, '--java-home', a.java_home, '--output', output]
    command += ['--phases', a.phases, '--sample-ms', a.sample_ms, '--load-scale', a.load_scale]
    command += ['--load-step-ms', a.load_step_ms]
    if a.output_height is not None: command += ['--output-height', a.output_height]
    if enabled:
        if a.adaptive_pacing:
            command.append('--adaptive-pacing')
            command += ['--adaptive-safety-margin-ms', str(a.adaptive_safety_margin_ms)]
            command += ['--adaptive-window-size', str(a.adaptive_window_size)]
        elif a.schedule_ms: command += ['--schedule-ms', str(a.schedule_ms)]
        else: command.append('--fresh')
    if a.telemetry: command.append('--telemetry')
    if a.fullscreen: command.append('--fullscreen')
    if a.sdr: command.append('--sdr')
    print(f'Starting {output.name} with {current_jar.name}', flush=True)
    # fresh-bench owns and bounds its game child. Stop on any failed game run.
    subprocess.run(list(map(str, command)), check=True)
    analyzed = subprocess.run([sys.executable, str(here / 'fresh-analyze.py'), str(output / 'measurements.json')])
    summary = json.loads((output / 'summary.json').read_text())
    if analyzed.returncode not in (0, 2) or not all(row['validContext'] for row in summary.values()):
        raise RuntimeError('Invalid test context; stopped before further sessions')
    if analyzed.returncode:
        print('Incomplete timestamp coverage retained and flagged; continuing the counterbalanced matrix.', flush=True)
print('All four sessions have closed. Results:', a.output, flush=True)
