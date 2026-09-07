#!/usr/bin/env python3
"""Read-only sampling of one explicitly supplied LumaRing process."""
import argparse
import json
import subprocess
import time
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument("pid", type=int)
parser.add_argument("--seconds", type=int, default=20)
parser.add_argument("--output", default="work/idle-measurement.json")
args = parser.parse_args()
command = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "command="], text=True).strip()
if "/LumaRing.app/Contents/MacOS/LumaRing" not in command:
    raise SystemExit("Refusing to sample a process other than the LumaRing app.")

samples = []
started = time.monotonic()
for index in range(args.seconds + 1):
    output = subprocess.check_output(["ps", "-p", str(args.pid), "-o", "%cpu=,rss=,time="], text=True).strip().split()
    samples.append({"elapsed": round(time.monotonic() - started, 3), "cpu_percent_ps": float(output[0]),
                    "rss_kib": int(output[1]), "cpu_time": output[2]})
    if index < args.seconds:
        time.sleep(1)

def cpu_seconds(value):
    fields = value.split(":")
    return sum(float(part) * (60 ** i) for i, part in enumerate(reversed(fields)))

duration = samples[-1]["elapsed"]
cpu_delta = cpu_seconds(samples[-1]["cpu_time"]) - cpu_seconds(samples[0]["cpu_time"])
report = {"pid": args.pid, "duration_seconds": duration,
          "cpu_seconds_delta": round(cpu_delta, 3),
          "average_cpu_percent_from_time": round(100 * cpu_delta / duration, 3),
          "rss_mib_min": round(min(s["rss_kib"] for s in samples) / 1024, 2),
          "rss_mib_max": round(max(s["rss_kib"] for s in samples) / 1024, 2),
          "samples": samples,
          "note": "ps CPU time resolution is 0.01s; 0.00 does not imply absolute zero energy use."}
path = Path(args.output)
path.parent.mkdir(parents=True, exist_ok=True)
path.write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps({k: v for k, v in report.items() if k != "samples"}, indent=2))
