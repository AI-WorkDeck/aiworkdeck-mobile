#!/usr/bin/env python3
"""Create an isolated regular iPhone, large iPhone, or Duo simulator for CI."""
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
            name = device["name"]
            is_large = "Pro Max" in name or "Plus" in name
            if not name.startswith("iPhone") or is_duo != (family == "duo"):
                continue
            if not is_duo and is_large != (family == "iphone-large"):
                continue
            if is_duo and version < (27, 1):
                continue
            generation = re.search(r"iPhone (\d+)", name)
            rank = (version, int(generation[1]) if generation else 0,
                    bool(re.fullmatch(r"iPhone \d+", name)), "Pro Max" in name, name)
            candidates.append((rank, runtime, device))
    if not candidates:
        raise ValueError(f"No compatible release iOS runtime/device for {family}; do not substitute another family")
    _, runtime, device = max(candidates, key=lambda item: item[0])
    return runtime, device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("family", choices=("iphone", "iphone-large", "duo"))
    parser.add_argument("--check-only", action="store_true", help="Check availability without creating a device")
    args = parser.parse_args()
    inventory = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "runtimes", "-j"]))
    runtime, device = select_device(inventory["runtimes"], args.family)
    print(f"Testing {device['name']} / iOS {runtime['version']} ({runtime['buildversion']})", file=sys.stderr)
    if args.check_only:
        return
    udid = subprocess.check_output(["xcrun", "simctl", "create", f"AWD CI {args.family}",
                                    device["identifier"], runtime["identifier"]], text=True).strip()
    print(udid)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(str(error))
