#!/usr/bin/env python3
"""Capture the real Watch home screen in a new, disposable simulator.

Uses an installed watchOS runtime; never downloads one or touches signing/ASC.
The only seeded state is the existing locale preference (no account/project).
Review the resulting screenshots before uploading them to App Store Connect.
"""

import hashlib
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[1]
BUNDLE = "com.aiworkdeck.mobile.cn.watchkitapp"


def run(*args, timeout=180, check=True):
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout, check=False)
    if check and result.returncode:
        raise RuntimeError(f"Command failed: {args}\n{result.stdout}")
    return result.stdout.strip()


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    runtimes = json.loads(run("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
    choices = [r for r in runtimes if r.get("isAvailable") and "watchOS" in r["identifier"]]
    if not choices:
        raise RuntimeError("No installed watchOS simulator runtime; choose a runner with watchOS installed")
    runtime = max(choices, key=lambda r: tuple(int(x) for x in r["version"].split(".")))
    types = runtime.get("supportedDeviceTypes") or json.loads(
        run("xcrun", "simctl", "list", "devicetypes", "-j"))["devicetypes"]
    # 46 mm Series 10/11/12 use the same accepted 416 x 496 screenshot size.
    watch = next((d for d in types if "Apple Watch Series" in d["name"] and "46mm" in d["name"]), None)
    if watch is None:
        raise RuntimeError("This watchOS runtime has no supported 46 mm Apple Watch")
    udid = run("xcrun", "simctl", "create", "AWD Store Screenshots", watch["identifier"], runtime["identifier"])
    evidence = {"commit": run("git", "rev-parse", "HEAD"), "runtime": runtime["identifier"],
                "device": watch["name"], "udid": udid, "screenshots": [],
                "state": "Real home screen; locale only, no account or project seeded"}
    try:
        run("xcodegen", "generate", "--spec", "ios/project.yml", "--project", "ios")
        with tempfile.TemporaryDirectory(prefix="awd-watch-derived-") as derived:
            build = run("xcodebuild", "build", "-project", "ios/Workdeck.xcodeproj",
                        "-scheme", "WorkdeckWatch", "-configuration", "Debug",
                        "-destination", f"platform=watchOS Simulator,id={udid}",
                        "-derivedDataPath", derived, "CODE_SIGNING_ALLOWED=NO", timeout=900)
            (output / "build.log").write_text(build)
            app = Path(derived) / "Build/Products/Debug-watchsimulator/WorkdeckWatch.app"
            run("xcrun", "simctl", "bootstatus", udid, "-b")
            run("xcrun", "simctl", "install", udid, str(app))
            container = Path(run("xcrun", "simctl", "get_app_container", udid, BUNDLE, "data"))
            run("xcrun", "simctl", "shutdown", udid)
            prefs = container / "Library/Preferences" / f"{BUNDLE}.plist"
            for locale, language in (("zh-Hans", "zh-Hans"), ("en-US", "en")):
                # The app follows the phone-account locale, not AppleLanguages.
                # Write only this existing preference while cfprefsd is stopped.
                data = plistlib.loads(prefs.read_bytes()) if prefs.exists() else {}
                data["watchContext"] = json.dumps({"destination": None, "locale": language}).encode()
                prefs.parent.mkdir(parents=True, exist_ok=True)
                prefs.write_bytes(plistlib.dumps(data))
                run("xcrun", "simctl", "bootstatus", udid, "-b")
                run("xcrun", "simctl", "status_bar", udid, "override", "--time", "09:41", check=False)
                launch = run("xcrun", "simctl", "launch", udid, BUNDLE)
                time.sleep(8)
                folder = output / locale
                folder.mkdir(exist_ok=True)
                shot = folder / "01-watch-home.jpg"
                run("xcrun", "simctl", "io", udid, "screenshot", "--type=jpeg", "--mask=black", str(shot))
                evidence["screenshots"].append({"locale": locale, "launch": launch,
                    "sha256": hashlib.sha256(shot.read_bytes()).hexdigest(),
                    "size": run("sips", "-g", "pixelWidth", "-g", "pixelHeight", str(shot))})
                run("xcrun", "simctl", "shutdown", udid)
    finally:
        (output / "evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
        run("xcrun", "simctl", "shutdown", udid, check=False)
        run("xcrun", "simctl", "delete", udid, check=False)


if __name__ == "__main__":
    main()
