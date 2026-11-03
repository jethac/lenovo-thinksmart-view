#!/usr/bin/env python3
"""Run one of Paradee's training scripts with the shared-GPU memory cap
(TORCH_MEM_FRACTION), TF32 and cuDNN autotuning on, and PyTorch's CPU
threads pinned (TORCH_THREADS, default: the container's CPU quota, at most
8). Unpinned, PyTorch starts one thread per visible core (64 on a RunPod
host, 20 on the PGX) inside a 4-16 CPU quota, and the CPU work of every step
(collate, losses) thrashes: 0.91 s a step instead of 0.32 on an RTX 5090.
    run.py scripts/NAME.py ARGS..."""
import os, runpy, sys


def quota():
    try:
        q, p = open("/sys/fs/cgroup/cpu.max").read().split()
        return max(1, int(int(q) / int(p))) if q != "max" else len(os.sched_getaffinity(0))
    except Exception:
        return len(os.sched_getaffinity(0))


n = int(os.environ.get("TORCH_THREADS") or min(8, quota()))
os.environ.setdefault("OMP_NUM_THREADS", str(n))
import torch  # noqa: E402
torch.set_num_threads(n)
f = float(os.environ.get("TORCH_MEM_FRACTION") or 0)
if f and torch.cuda.is_available():
    torch.cuda.set_per_process_memory_fraction(f)
torch.backends.cuda.matmul.allow_tf32 = True
torch.backends.cudnn.allow_tf32 = True
if os.environ.get("CUDNN_BENCHMARK", "1") == "1":
    torch.backends.cudnn.benchmark = True
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name="__main__")
