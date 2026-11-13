#!/usr/bin/env python3
"""Print the UDID of the best available iPhone simulator (newest iOS, prefer "iPhone NN Pro")."""
import json
import re
import subprocess
import sys

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    m = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not m:
        continue
    version = (int(m.group(1)), int(m.group(2)))
    for d in devices:
        name = d["name"]
        if not name.startswith("iPhone"):
            continue
        score = (version, 1 if re.fullmatch(r"iPhone \d+ Pro", name) else 0)
        if best is None or score > best[0]:
            best = (score, d["udid"], name, runtime)

if best is None:
    sys.exit("No iPhone simulator available")
print(f"Using {best[2]} ({best[3].split('.')[-1]})", file=sys.stderr)
print(best[1])
