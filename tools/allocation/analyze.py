"""Summarize allocation counters, weighted JFR samples, GC pauses and overlapping frame intervals."""
import argparse
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('profile', type=Path)
p.add_argument('--java-home', type=Path, required=True)
a = p.parse_args()

def epoch_ns(text):
    match = re.fullmatch(r'(.*T\d+:\d+:\d+)(?:\.(\d+))?([+-]\d+:\d+|Z)', text)
    whole, fraction, zone = match.groups()
    return int(datetime.fromisoformat(whole + zone).timestamp()) * 10**9 + int((fraction or '').ljust(9, '0'))

def duration_ns(text):
    return round(float(text[2:-1]) * 1e9)

def percentile(values, q):
    return sorted(values)[int((len(values) - 1) * q)] if values else None

summary = {}
for phase in ('stationary', 'flight'):
    path = a.profile / f'{phase}-events.json'
    with path.open('w') as f:
        subprocess.run([str(a.java_home / 'bin/jfr'), 'print', '--json', '--events',
            'jdk.ObjectAllocationSample,jdk.GCPhasePause,jdk.GarbageCollection',
            str(a.profile / f'{phase}.jfr')], stdout=f, check=True)
    report = json.loads((a.profile / f'{phase}.json').read_text())
    events = json.loads(path.read_text())['recording']['events']
    seconds = report['durationNs'] / 1e9
    offset = report['clockEpochNs'] - report['clockNano']
    frames = [n + offset for n in report['frameNs']]
    intervals = [(x, y, (y - x) / 1e6) for x, y in zip(frames, frames[1:])]
    pauses = []
    samples = Counter()
    seen = set()
    for event in events:
        v = event['values']
        start = epoch_ns(v['startTime'])
        if event['type'] == 'jdk.GCPhasePause':
            end = start + duration_ns(v['duration'])
            if start <= frames[-1] and end >= frames[0]: pauses.append((start, end))
        elif event['type'] == 'jdk.ObjectAllocationSample':
            tid = v['eventThread']['javaThreadId']
            # First samples can carry bytes allocated before the recording began. They otherwise dwarf the phase.
            if tid not in seen:
                seen.add(tid)
                continue
            if not frames[0] <= start <= frames[-1]: continue
            stack = (v.get('stackTrace') or {}).get('frames', [])
            key = ' > '.join(f["method"]["type"]["name"] + '.' + f['method']['name'] + ':' + str(f['lineNumber']) for f in stack[:5])
            samples[key] += v['weight']
    durations = [ms for _, _, ms in intervals]
    overlap = [ms for x, y, ms in intervals if any(x < b and y > s for s, b in pauses)]
    no_overlap = [ms for x, y, ms in intervals if not any(x < b and y > s for s, b in pauses)]
    summary[phase] = {
        'seconds': seconds,
        'allocatedMiBPerSecond': sum(t['bytes'] for t in report['threadAllocatedBytes']) / seconds / 2**20,
        'threadCountersNote': 'Counters cover threads alive at the end; terminated workers may be missed.',
        'frames': len(frames), 'averageFps': (len(frames) - 1) * 1e9 / (frames[-1] - frames[0]),
        'frameMs': {str(q): percentile(durations, q) for q in (.5, .95, .99, 1)},
        'framesOver20ms': sum(ms > 20 for ms in durations),
        'framesOver50ms': sum(ms > 50 for ms in durations),
        'gcCount': len(pauses), 'gcTotalMs': sum(b-s for s,b in pauses)/1e6,
        'gcMaxMs': max((b-s for s,b in pauses), default=0)/1e6,
        'gcOverlappingFrames': len(overlap), 'gcOverlappingFrameMaxMs': max(overlap, default=0),
        'nonGcFrameMaxMs': max(no_overlap, default=0), 'clockBracketNs': report['clockBracketNs'],
        'unfocusedFrames': report['unfocusedFrames'], 'fullscreenFrames': report['fullscreenFrames'],
        'sampledMiBPerSecond': sum(samples.values()) / seconds / 2**20,
        'topSampledStacks': [{'stack': k, 'MiBPerSecond': v / seconds / 2**20} for k,v in samples.most_common(30)],
    }
(a.profile / 'analysis.json').write_text(json.dumps(summary, indent=2) + '\n')
for phase, s in summary.items():
    print(f"{phase}: {s['allocatedMiBPerSecond']:.1f} MiB/s; {s['gcCount']} GC pauses / {s['gcTotalMs']:.1f} ms total / {s['gcMaxMs']:.2f} ms max; "
          f"{s['averageFps']:.1f} FPS; p99 frame {s['frameMs']['0.99']:.2f} ms / max {s['frameMs']['1']:.2f} ms; >20ms {s['framesOver20ms']}")
