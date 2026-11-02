# Copyright 2026 mcopt-shade contributors. Licensed under the Apache License, Version 2.0.
"""Summarize only steady measurement windows and report invalid coverage explicitly."""
import argparse
import collections
import json
import math
import statistics
import sys
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("report", type=Path)
args = parser.parse_args()
data = json.loads(args.report.read_text())
gpu = data["gpu"]

def percentile(values, quantile):
    if not values:
        return None
    values = sorted(values)
    return values[max(0, math.ceil(len(values) * quantile) - 1)]

def summary(values):
    return {
        "n": len(values),
        "mean": statistics.mean(values) if values else None,
        "p50": percentile(values, .5), "p95": percentile(values, .95),
        "p99": percentile(values, .99), "max": max(values) if values else None,
        "stddev": statistics.pstdev(values) if values else None,
    }

def fmt(value):
    return "unavailable" if value is None else f"{value:.2f}"

result = {}
for name, phase in data["phases"].items():
    begin, end = phase["nanoRange"]
    fullscreen = phase["fullscreen"]
    context = phase["context"]
    native_valid = (context["nativeFullscreen"] is fullscreen and context["focused"] is True
        and context["vsync"] is True and context["hdr"] is phase["hdr"]
        and context["drawableWidth"] == phase["width"] and context["drawableHeight"] == phase["height"])
    indices = [i for i, yes in enumerate(gpu["presenting"])
               if yes and begin <= gpu["pollNs"][i] < end]
    shown = [gpu["presentedTimeNs"][i] for i in indices if begin <= gpu["presentedTimeNs"][i] < end]
    duplicate_times = len(shown) - len(set(shown))
    ordered = sorted(set(shown))
    intervals = [(b - a) / 1e6 for a, b in zip(ordered, ordered[1:])]
    latency = [(gpu["presentedTimeNs"][i] - gpu["pollNs"][i]) / 1e6 for i in indices
               if begin <= gpu["presentedTimeNs"][i] < end and gpu["pollNs"][i] <= gpu["presentedTimeNs"][i]]
    durations = [(gpu["gpuEndNs"][i] - gpu["gpuStartNs"][i]) / 1e6 for i in indices
                 if 0 < gpu["gpuStartNs"][i] <= gpu["gpuEndNs"][i]]
    polls = sorted(set(gpu["pollNs"][i] for i in indices))
    poll_intervals = [(b - a) / 1e6 for a, b in zip(polls, polls[1:])]
    # Keep signed deltas. Some paths report presentation before the associated
    # command buffer's GPU completion; dropping those would bias this diagnostic
    # toward a positive "display wait" that the data does not establish.
    gpu_to_shown = [(gpu["presentedTimeNs"][i] - gpu["gpuEndNs"][i]) / 1e6 for i in indices
                    if begin <= gpu["presentedTimeNs"][i] < end and gpu["gpuEndNs"][i] > 0]
    target = 1000 / phase["cap"]
    states = gpu["presentationState"]
    unknown = sum(not gpu["presentedTimeNs"][i] and states[i] not in (2, 3, 4) for i in indices)
    contradictory = sum(states[i] in (2, 3, 4) and gpu["presentedTimeNs"][i] != 0 for i in indices)
    q0, q1 = phase["queueStart"], phase["queueEnd"]
    delta = {k: q1[k] - q0[k] for k in ("checks", "replacements", "selectedFrameAgeSavedNs", "drawableWaitNs")}
    # Count all reported presentations in complete one-second windows. Include
    # frames polled just before the phase begins, since they were still displayed.
    phase_presentations = sorted(set(t for t in gpu["presentedTimeNs"] if begin <= t < end))
    per_second = [sum(begin + second * 1_000_000_000 <= t < begin + (second + 1) * 1_000_000_000
                      for t in phase_presentations) for second in range((end - begin) // 1_000_000_000)]
    row = result[name] = {
        "cap": phase["cap"], "fresh": phase["fresh"], "variableGpuLoad": phase["load"],
        "candidate": phase.get("candidate", phase["fresh"]), "scheduleMs": phase.get("scheduleMs", 0),
        "adaptivePacing": phase.get("adaptivePacing", False),
        "adaptiveSafetyMarginMs": phase.get("adaptiveSafetyMarginMs", 1.5),
        "adaptiveWindowSize": phase.get("adaptiveWindowSize", 8),
        "loadScale": phase.get("loadScale", 1), "loadStepMs": phase.get("loadStepMs", 237),
        "fullscreen": fullscreen, "windowContext": context,
        "validContext": native_valid and phase["frames"] > 0
            and phase["unfocused"] + phase["wrongMode"] + phase["changedSize"] + phase["moved"] == 0
            and q0["enabled"] is phase["fresh"] and q1["enabled"] is phase["fresh"]
            and phase["caps"] == {str(phase["cap"]): phase["frames"]},
        "queueDelta": delta,
        "meanSelectedFrameAgeSavedMs": delta["selectedFrameAgeSavedNs"] / delta["replacements"] / 1e6 if delta["replacements"] else None,
        "presentationStates": dict(collections.Counter(states[i] for i in indices)),
        "unexplainedMissingTimestamps": unknown, "contradictoryDiscardedFrames": contradictory,
        "presentingSubmits": len(indices),
        "missingPresentationTimestamps": sum(gpu["presentedTimeNs"][i] == 0 for i in indices),
        # Read at report time, after all phases and a final drain period. A zero
        # callback is distinct from a delivered callback reporting no presentation;
        # neither is silently discarded when assessing measurement coverage.
        "missingPresentedCallbacks": sum(gpu["presentedHandlerNs"][i] == 0 for i in indices),
        "callbacksWithoutPresentation": sum(gpu["presentedHandlerNs"][i] > 0
            and gpu["presentedTimeNs"][i] == 0 for i in indices),
        "duplicatePresentationTimestamps": duplicate_times,
        "intervalMs": summary(intervals), "pollToPresentationMs": summary(latency),
        "gpuMs": summary(durations),
        "pollIntervalMs": summary(poll_intervals), "gpuEndToPresentationMs": summary(gpu_to_shown),
        "presentationBeforeGpuCompletion": sum(delta < 0 for delta in gpu_to_shown),
        "intervalHistogramMs": dict(sorted(collections.Counter(round(x * 2) / 2 for x in intervals).items())),
        "meanAbsoluteIntervalErrorMs": statistics.mean(abs(x - target) for x in intervals) if intervals else None,
        "longIntervalsOver1_5Periods": sum(x > 1.5 * target for x in intervals),
        "intervalsOver50Ms": sum(x > 50 for x in intervals),
        "intervalsOver100Ms": sum(x > 100 for x in intervals),
        "presentedFramesPerSecond": per_second,
    }
    row["displayedFps"] = 1000 / statistics.mean(intervals) if intervals else None
    if "scheduleBudgetNs" in q0:
        row["scheduleDelta"] = {k: q1[k] - q0[k] for k in ("scheduled", "expiredDeadlines")}
        row["validContext"] &= (abs(q0["scheduleBudgetNs"] / 1e6 - row["scheduleMs"]) < .0001
                                and q0["scheduleBudgetNs"] == q1["scheduleBudgetNs"])
    # Separate regular input polling from CPU submission, GPU completion and
    # presentation cadence. A steady cap alone does not prove steady frame delivery.
    for source, label in (("submitNs", "submitIntervalMs"), ("gpuEndNs", "renderGpuEndIntervalMs"),
                          ("presentGpuEndNs", "presentGpuEndIntervalMs")):
        if source in gpu:
            times = sorted(set(gpu[source][i] for i in indices if gpu[source][i] > 0))
            row[label] = summary([(b - a) / 1e6 for a, b in zip(times, times[1:])])
    for start, finish, label in (("pollNs", "submitNs", "pollToSubmitMs"),
                                 ("submitNs", "gpuStartNs", "submitToGpuStartMs")):
        row[label] = summary([(gpu[finish][i] - gpu[start][i]) / 1e6 for i in indices
                              if gpu[start][i] > 0 and gpu[finish][i] > 0])
    if "presentGpuEndNs" in gpu:
        selected = [i for i in indices if begin <= gpu["presentedTimeNs"][i] < end]
        valid_ends = [i for i in selected if gpu["presentGpuEndNs"][i] > 0 and gpu["gpuEndNs"][i] > 0]
        row["missingPresentGpuEnd"] = len(selected) - len(valid_ends)
        # Signed deltas are retained: a negative value is evidence to investigate,
        # not a sample to silently remove from a claimed queue-delay distribution.
        row["renderEndToPresentGpuEndMs"] = summary([(gpu["presentGpuEndNs"][i] - gpu["gpuEndNs"][i]) / 1e6 for i in valid_ends])
        row["presentGpuEndToShownMs"] = summary([(gpu["presentedTimeNs"][i] - gpu["presentGpuEndNs"][i]) / 1e6 for i in valid_ends])
        if row["scheduleMs"] > 0 and valid_ends:
            # The benchmark poll stamp is adjacent to the native scheduling hook,
            # not that hook's exact timestamp. Treat this as a readiness estimate.
            ready = [(gpu["presentGpuEndNs"][i] - gpu["pollNs"][i]) / 1e6 for i in valid_ends]
            row["estimatedGpuReadyAfterTargetPercent"] = 100 * sum(t > row["scheduleMs"] for t in ready) / len(ready)
            row["deadlineMissPercent"] = row["estimatedGpuReadyAfterTargetPercent"]
            row["deadlineHitPercent"] = 100.0 - row["deadlineMissPercent"]
    tel_file = args.report.with_name("telemetry.json")
    if tel_file.exists() and row.get("adaptivePacing"):
        try:
            tel_data = json.loads(tel_file.read_text())
            tel_recs = [r for r in tel_data.get("records", [])
                        if begin <= r.get("commitNs", 0) < end and r.get("targetPresNs", 0) > 0 and r.get("presentGpuEndNs", 0) > 0]
            if tel_recs:
                hits = sum(r["presentGpuEndNs"] <= r["targetPresNs"] for r in tel_recs)
                row["deadlineHitPercent"] = 100.0 * hits / len(tel_recs)
                row["deadlineMissPercent"] = 100.0 - row["deadlineHitPercent"]
        except Exception:
            pass
    row["validForComparison"] = (row["validContext"] and len(intervals) >= 10
        and unknown <= 5 and contradictory == 0 and duplicate_times == 0
        and len(latency) == len(shown) and gpu["dropped"] == 0)
    hit_disp = f" hit={row['deadlineHitPercent']:.1f}%" if "deadlineHitPercent" in row else ""
    print(f"{name:14} candidate={row['candidate']} fresh={row['fresh']} adaptive={row['adaptivePacing']}{hit_disp} replacements={delta['replacements']} context={row['validContext']} comparison={row['validForComparison']} shown={len(shown)} "
          f"FPS={fmt(row['displayedFps'])} interval mean/p95={fmt(row['intervalMs']['mean'])}/{fmt(row['intervalMs']['p95'])}ms "
          f"jitter SD={fmt(row['intervalMs']['stddev'])}ms "
          f"poll->shown median/p95={fmt(row['pollToPresentationMs']['p50'])}/{fmt(row['pollToPresentationMs']['p95'])}ms "
          f"GPU median={fmt(row['gpuMs']['p50'])}ms")
    print("  interval bins:", row["intervalHistogramMs"])
    if "presentGpuEndNs" in gpu:
        print("  median render end -> present GPU end -> shown:",
            fmt(row["renderEndToPresentGpuEndMs"]["p50"]), "+", fmt(row["presentGpuEndToShownMs"]["p50"]),
            "ms; missing present GPU timestamps:", row["missingPresentGpuEnd"])
    if row["missingPresentationTimestamps"]:
        print(f"  coverage: {unknown} unexplained, {row['missingPresentationTimestamps']} total absent (includes intentional replacements), "
              f"{row['missingPresentedCallbacks']} callbacks missing, "
              f"{row['callbacksWithoutPresentation']} callbacks without presentation")
path = args.report.with_name("summary.json")
path.write_text(json.dumps(result, indent=2) + "\n")
print(path)
if not result or not all(row["validForComparison"] for row in result.values()):
    print("INVALID COMPARISON: check focus, actual cap, pacing state, HDR, and timestamp coverage.", file=sys.stderr)
    raise SystemExit(2)
