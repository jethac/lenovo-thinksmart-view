#!/usr/bin/env python3
"""Last values of a Matcha run's TensorBoard scalars, with the step rate.

    tb-tail.py RUN_DIR [TAG...]
"""
import glob, sys
from tensorboard.backend.event_processing.event_accumulator import EventAccumulator

ev = sorted(glob.glob(f"{sys.argv[1]}/tensorboard/version_*/events.*"))[-1]
ea = EventAccumulator(ev, size_guidance={"scalars": 0})
ea.Reload()
tags = sys.argv[2:] or [t for t in ea.Tags()["scalars"] if "epoch" in t or t.startswith("sub_loss/val")]
for t in tags:
    if t not in ea.Tags()["scalars"]:
        continue
    s = ea.Scalars(t)
    print(f"{t}: step {s[-1].step} {s[-1].value:.4f}" + (f" (first {s[0].value:.4f})" if len(s) > 1 else ""))
s = ea.Scalars("loss/train_step")
if len(s) > 1:
    print(f"rate {(s[-1].step - s[0].step) / (s[-1].wall_time - s[0].wall_time):.2f} steps/s, last step {s[-1].step}")
