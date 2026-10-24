#!/usr/bin/env python3
"""Reject release environments and IPAs that cannot provide native Duo layouts."""
import argparse
import json
import plistlib
import re
import subprocess
import zipfile

MIN_VERSION = (27, 1)


def version(value):
    if not re.fullmatch(r"\d+\.\d+(?:\.\d+)?", value):
        raise ValueError(f"Unrecognized version: {value!r}")
    return tuple(map(int, value.split(".")))


def release_build(value, label):
    # Final Xcode 27.1 uses the same build as its RC, despite the runner's path.
    if not re.fullmatch(r"\d+[A-Z]\d+", str(value)):
        raise ValueError(f"{label} is missing or is not a release build: {value!r}")


def check_environment(os_build, xcode_output, sdk_version, sdk_build):
    release_build(os_build, "macOS")
    match = re.fullmatch(r"Xcode ([\d.]+)\s+Build version (\S+)", xcode_output.strip())
    if not match or version(match[1]) < MIN_VERSION:
        raise ValueError("Release requires Xcode 27.1 or newer")
    release_build(match[2], "Xcode")
    if version(sdk_version) < MIN_VERSION:
        raise ValueError("Release requires iPhoneOS SDK 27.1 or newer")
    release_build(sdk_build, "iPhoneOS SDK")
    return {"macOSBuild": os_build, "xcode": match[1], "xcodeBuild": match[2],
            "sdk": sdk_version, "sdkBuild": sdk_build}


def check_metadata(info):
    if info.get("CFBundleIdentifier") != "com.aiworkdeck.mobile.cn":
        raise ValueError("IPA does not contain the AI WorkDeck main app")
    if info.get("DTPlatformName") != "iphoneos":
        raise ValueError("IPA must target iPhoneOS, not a simulator")
    xcode = str(info.get("DTXcode", ""))
    if not xcode.isdigit() or int(xcode) < 2710:
        raise ValueError("IPA was not built with Xcode 27.1 or newer")
    sdk = re.fullmatch(r"iphoneos([\d.]+)", str(info.get("DTSDKName", "")))
    if not sdk or version(sdk[1]) < MIN_VERSION:
        raise ValueError("IPA was not built with iPhoneOS SDK 27.1 or newer")
    for key in ("BuildMachineOSBuild", "DTXcodeBuild", "DTSDKBuild"):
        release_build(info.get(key), key)
    return {key: info.get(key) for key in (
        "CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
        "DTXcode", "DTXcodeBuild", "DTSDKName", "DTSDKBuild", "BuildMachineOSBuild")}


def check_ipa(path):
    with zipfile.ZipFile(path) as archive:
        names = [name for name in archive.namelist()
                 if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(names) != 1:
            raise ValueError("IPA must have exactly one main app Info.plist")
        return check_metadata(plistlib.loads(archive.read(names[0])))


def read(*args):
    return subprocess.check_output(args, text=True).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("check", choices=("environment", "ipa"))
    parser.add_argument("path", nargs="?")
    args = parser.parse_args()
    if args.check == "environment":
        result = check_environment(read("sw_vers", "-buildVersion"), read("xcodebuild", "-version"),
                                   read("xcrun", "--sdk", "iphoneos", "--show-sdk-version"),
                                   read("xcrun", "--sdk", "iphoneos", "--show-sdk-build-version"))
    else:
        if not args.path:
            parser.error("ipa requires a path")
        result = check_ipa(args.path)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, zipfile.BadZipFile,
            plistlib.InvalidFileException) as error:
        raise SystemExit(f"iOS release check failed: {error}")
