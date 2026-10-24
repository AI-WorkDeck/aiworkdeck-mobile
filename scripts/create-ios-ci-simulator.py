#!/usr/bin/env python3
"""Create an isolated, runtime-compatible iPhone or Duo simulator for CI."""
import argparse
import json
import re
import subprocess
import sys


def select_device(runtimes, family):
    candidates = []
    for runtime in runtimes:
        if (not runtime.get("isAvailable") or runtime.get("platform") != "iOS"
                or not re.fullmatch(r"\d+[A-Z]\d+", runtime.get("buildversion", ""))):
            continue
        version = tuple(map(int, runtime["version"].split(".")))
        for device in runtime.get("supportedDeviceTypes", []):
            is_duo = device["name"] == "iPhone Duo"
            if not device["name"].startswith("iPhone") or is_duo != (family == "duo"):
                continue
            if is_duo and version < (27, 1):
                continue
            candidates.append((version, "Pro Max" in device["name"], device["name"], runtime, device))
    if not candidates:
        raise ValueError(f"No compatible release iOS runtime/device for {family}; do not substitute another family")
    _, _, _, runtime, device = max(candidates, key=lambda item: item[:3])
    return runtime, device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("family", choices=("iphone", "duo"))
    args = parser.parse_args()
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
    runtime, device = select_device(inventory["runtimes"], args.family)
    print(f"Testing {device['name']} / iOS {runtime['version']} ({runtime['buildversion']})", file=sys.stderr)
    udid = subprocess.check_output(["xcrun", "simctl", "create", f"AWD CI {args.family}",
                                    device["identifier"], runtime["identifier"]], text=True).strip()
    print(udid)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
