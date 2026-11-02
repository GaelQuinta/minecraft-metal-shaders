#!/usr/bin/env python3
# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
"""
Telemetry analysis tool for Metal shaders ProMotion diagnostics.
Analyzes in-memory telemetry ring buffer dump (telemetry.json) to compute:
- GPU execution duration variance: Var(Δt_gpu)
- GPU completion interval variance: Var(ΔT_gpu_comp)
- Presentation interval variance: Var(ΔT_pres)
- Input-to-presentation software latency distribution
- Quantization behavior relative to display refresh intervals
- Within-step steady-state variance under constant GPU load
"""

import sys
import json
import math
from pathlib import Path

def stats(arr):
    if not arr:
        return {"count": 0, "mean": 0.0, "var": 0.0, "std": 0.0, "min": 0.0, "max": 0.0, "p50": 0.0, "p95": 0.0}
    n = len(arr)
    mean = sum(arr) / n
    variance = sum((x - mean) ** 2 for x in arr) / (n - 1) if n > 1 else 0.0
    std = math.sqrt(variance)
    s_arr = sorted(arr)
    p50 = s_arr[int(n * 0.50)]
    p95 = s_arr[min(int(n * 0.95), n - 1)]
    return {
        "count": n,
        "mean": mean,
        "var": variance,
        "std": std,
        "min": s_arr[0],
        "max": s_arr[-1],
        "p50": p50,
        "p95": p95
    }

def print_dataset_analysis(label, records, step_ms=1000):
    if not records:
        print(f"No records for {label}")
        return

    records.sort(key=lambda r: r["presentedNs"])

    # 1. GPU Render Execution Duration: Δt_gpu = renderGpuEndNs - renderGpuStartNs
    gpu_durations_ms = [(r["renderGpuEndNs"] - r["renderGpuStartNs"]) / 1e6
                        for r in records if r.get("renderGpuEndNs", 0) > r.get("renderGpuStartNs", 0)]

    # 2. GPU Completion Interval: ΔT_gpu_comp = renderGpuEndNs[i] - renderGpuEndNs[i-1]
    gpu_comp_intervals_ms = []
    for i in range(1, len(records)):
        if records[i].get("renderGpuEndNs", 0) > 0 and records[i-1].get("renderGpuEndNs", 0) > 0:
            d = (records[i]["renderGpuEndNs"] - records[i-1]["renderGpuEndNs"]) / 1e6
            if 0 < d < 500:
                gpu_comp_intervals_ms.append(d)

    # 3. Presentation Interval: ΔT_pres = presentedNs[i] - presentedNs[i-1]
    pres_intervals_ms = []
    for i in range(1, len(records)):
        delta_pres = (records[i]["presentedNs"] - records[i - 1]["presentedNs"]) / 1e6
        if 0 < delta_pres < 500:
            pres_intervals_ms.append(delta_pres)

    # 4. Input-to-presentation latency: presentedNs - inputNs
    input_to_pres_ms = [(r["presentedNs"] - r["inputNs"]) / 1e6
                        for r in records if r.get("inputNs", 0) > 0 and r["presentedNs"] > r["inputNs"]]

    s_gpu_dur = stats(gpu_durations_ms)
    s_gpu_comp = stats(gpu_comp_intervals_ms)
    s_pres = stats(pres_intervals_ms)
    s_lat = stats(input_to_pres_ms)

    print("\n" + "=" * 76)
    print(f"  {label.upper()}")
    print("=" * 76)

    print(f"\n1. GPU Execution Duration (Δt_gpu = renderGpuEnd - renderGpuStart):")
    print(f"   Count:      {s_gpu_dur['count']} frames")
    print(f"   Mean:       {s_gpu_dur['mean']:.3f} ms  (Throughput: {1000.0/s_gpu_dur['mean'] if s_gpu_dur['mean']>0 else 0:.1f} FPS)")
    print(f"   Variance:   {s_gpu_dur['var']:.4f} ms²")
    print(f"   Std Dev:    {s_gpu_dur['std']:.3f} ms")
    print(f"   Min / Max:  {s_gpu_dur['min']:.3f} ms / {s_gpu_dur['max']:.3f} ms")
    print(f"   Median:     {s_gpu_dur['p50']:.3f} ms")

    print(f"\n2. GPU Completion Interval (ΔT_gpu_comp = renderGpuEnd[n] - renderGpuEnd[n-1]):")
    print(f"   Count:      {s_gpu_comp['count']} intervals")
    print(f"   Mean:       {s_gpu_comp['mean']:.3f} ms  (Cadence: {1000.0/s_gpu_comp['mean'] if s_gpu_comp['mean']>0 else 0:.1f} FPS)")
    print(f"   Variance:   {s_gpu_comp['var']:.4f} ms²")
    print(f"   Std Dev:    {s_gpu_comp['std']:.3f} ms")
    print(f"   Min / Max:  {s_gpu_comp['min']:.3f} ms / {s_gpu_comp['max']:.3f} ms")
    print(f"   Median:     {s_gpu_comp['p50']:.3f} ms")

    print(f"\n3. Presentation Interval (ΔT_pres = presented[n] - presented[n-1]):")
    print(f"   Count:      {s_pres['count']} intervals")
    print(f"   Mean:       {s_pres['mean']:.3f} ms  (Cadence: {1000.0/s_pres['mean'] if s_pres['mean']>0 else 0:.1f} FPS)")
    print(f"   Variance:   {s_pres['var']:.4f} ms²")
    print(f"   Std Dev:    {s_pres['std']:.3f} ms")
    print(f"   Min / Max:  {s_pres['min']:.3f} ms / {s_pres['max']:.3f} ms")
    print(f"   Median:     {s_pres['p50']:.3f} ms")

    print(f"\n4. Input-to-Presentation Software Latency (T_pres - T_input):")
    print(f"   Median:     {s_lat['p50']:.3f} ms")
    print(f"   p95:        {s_lat['p95']:.3f} ms")
    print(f"   Mean:       {s_lat['mean']:.3f} ms")

    ratio_comp = s_pres['var'] / s_gpu_comp['var'] if s_gpu_comp['var'] > 0 else float('inf')
    print(f"\n5. Empirical Variance Comparison:")
    print(f"   Var(ΔT_gpu_comp): {s_gpu_comp['var']:.4f} ms²  (Std: {s_gpu_comp['std']:.3f} ms)")
    print(f"   Var(ΔT_pres):     {s_pres['var']:.4f} ms²  (Std: {s_pres['std']:.3f} ms)")
    print(f"   Ratio Var(ΔT_pres) / Var(ΔT_gpu_comp): {ratio_comp:.2f}x")

    # Quantization breakdown
    print(f"\n6. Presentation Interval Quantization Breakdown:")
    bins = {
        "8.33ms (120Hz)": sum(1 for x in pres_intervals_ms if 7.0 <= x < 10.0),
        "16.67ms (60Hz)": sum(1 for x in pres_intervals_ms if 15.0 <= x < 18.5),
        "20.00ms (50Hz)": sum(1 for x in pres_intervals_ms if 18.5 <= x < 21.5),
        "22.22ms (45Hz)": sum(1 for x in pres_intervals_ms if 21.5 <= x < 23.5),
        "25.00ms (40Hz)": sum(1 for x in pres_intervals_ms if 23.5 <= x < 27.0),
        "33.33ms (30Hz)": sum(1 for x in pres_intervals_ms if 30.0 <= x < 37.0),
        "Other / Jitter": sum(1 for x in pres_intervals_ms if not (
            7.0 <= x < 10.0 or 15.0 <= x < 18.5 or 18.5 <= x < 21.5 or 21.5 <= x < 23.5 or 23.5 <= x < 27.0 or 30.0 <= x < 37.0))
    }
    for b_label, b_count in bins.items():
        pct = (b_count / len(pres_intervals_ms) * 100) if pres_intervals_ms else 0
        bar = "#" * int(pct / 2)
        print(f"   {b_label:18s}: {b_count:5d} ({pct:5.1f}%) | {bar}")

    # Within-step constant workload analysis
    step_ns = int(step_ms * 1e6)
    t0 = records[0]["presentedNs"]
    chunks = {}
    for r in records:
        c_idx = (r["presentedNs"] - t0) // step_ns
        chunks.setdefault(c_idx, []).append(r)

    print(f"\n7. Within-Step (Constant {step_ms}ms Workload) Variance Analysis:")
    print(f"   {'Step':<5} | {'Frames':<6} | {'GPU Exec (ms)':<15} | {'GPU Comp SD':<12} | {'Pres Int SD':<12} | {'Pres Var / GPU Var':<18}")
    print("   " + "-" * 72)

    step_comp_vars = []
    step_pres_vars = []

    for c_idx in sorted(chunks.keys()):
        c_recs = chunks[c_idx]
        if len(c_recs) < 5:
            continue
        c_gpu_durs = [(r["renderGpuEndNs"] - r["renderGpuStartNs"]) / 1e6
                      for r in c_recs if r.get("renderGpuEndNs", 0) > r.get("renderGpuStartNs", 0)]
        c_gpu_comps = [(c_recs[i]["renderGpuEndNs"] - c_recs[i-1]["renderGpuEndNs"]) / 1e6
                       for i in range(1, len(c_recs))
                       if c_recs[i].get("renderGpuEndNs", 0) > 0 and c_recs[i-1].get("renderGpuEndNs", 0) > 0]
        c_pres_ints = [(c_recs[i]["presentedNs"] - c_recs[i-1]["presentedNs"]) / 1e6
                       for i in range(1, len(c_recs))]

        s_cdur = stats(c_gpu_durs)
        s_ccomp = stats(c_gpu_comps)
        s_cpres = stats(c_pres_ints)

        ratio = s_cpres['var'] / s_ccomp['var'] if s_ccomp['var'] > 0 else 0.0
        step_comp_vars.append(s_ccomp['var'])
        step_pres_vars.append(s_cpres['var'])
        print(f"   {c_idx:<5} | {len(c_recs):<6} | {s_cdur['mean']:6.2f} +/- {s_cdur['std']:<4.2f}  | {s_ccomp['std']:6.3f} ms   | {s_cpres['std']:6.3f} ms   | {ratio:6.2f}x")

    if step_comp_vars and step_pres_vars:
        avg_comp_v = sum(step_comp_vars) / len(step_comp_vars)
        avg_pres_v = sum(step_pres_vars) / len(step_pres_vars)
        print("   " + "-" * 72)
        print(f"   Mean within-step GPU completion variance: {avg_comp_v:.4f} ms² (SD: {math.sqrt(avg_comp_v):.3f} ms)")
        print(f"   Mean within-step Presentation variance:   {avg_pres_v:.4f} ms² (SD: {math.sqrt(avg_pres_v):.3f} ms)")
        print(f"   Mean within-step Variance Ratio (Pres / GPU): {avg_pres_v / avg_comp_v:.2f}x")

    print("=" * 76 + "\n")

    return {
        "gpuDuration": s_gpu_dur,
        "gpuCompletion": s_gpu_comp,
        "presInterval": s_pres,
        "inputLatency": s_lat,
        "varianceRatio": ratio_comp,
        "withinStep": {
            "meanGpuCompVar": avg_comp_v if step_comp_vars else 0,
            "meanPresVar": avg_pres_v if step_pres_vars else 0,
            "varianceRatio": (avg_pres_v / avg_comp_v) if step_comp_vars and avg_comp_v > 0 else 0
        } if step_comp_vars else None,
        "quantization": bins
    }

def analyze_telemetry(filepath):
    p = Path(filepath)
    if not p.exists():
        print(f"Error: {filepath} does not exist", file=sys.stderr)
        sys.exit(1)

    data = json.loads(p.read_text())
    records = data.get("records", [])
    print(f"Loaded {len(records)} records from {filepath} (Ring buffer capacity: {data.get('capacity', 'unknown')})")

    presented = [r for r in records if r.get("state") == 1 and r.get("presentedNs", 0) > 0]
    print(f"Successfully presented frames: {len(presented)} / {len(records)}")

    # Check for companion measurements.json
    meas_path = p.with_name("measurements.json")
    results = {}

    if meas_path.exists():
        meas = json.loads(meas_path.read_text())
        phases = meas.get("phases", {})
        for phase_name, pdata in phases.items():
            if "nanoRange" in pdata:
                nr = pdata["nanoRange"]
                step_ms = pdata.get("loadStepMs", 1000)
                phase_recs = [r for r in presented if nr[0] <= r.get("presentedNs", 0) <= nr[1]]
                print(f"\nFound phase '{phase_name}' in measurements.json: {len(phase_recs)} frames in window [{nr[0]}..{nr[1]}]")
                results[phase_name] = print_dataset_analysis(f"Phase {phase_name} Steady-State Diagnostic", phase_recs, step_ms=step_ms)

    # Full session analysis
    results["full_session"] = print_dataset_analysis("Full Diagnostic Session", presented)

    out_summary_path = p.with_name("telemetry_analysis.json")
    out_summary_path.write_text(json.dumps(results, indent=2))
    print(f"Complete telemetry analysis written to {out_summary_path}")

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <path_to_telemetry.json>")
        sys.exit(1)
    analyze_telemetry(sys.argv[1])
