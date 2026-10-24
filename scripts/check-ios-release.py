#!/usr/bin/env python3
"""Reject release environments and IPAs that cannot provide native Duo layouts."""
import argparse
import json
import plistlib
import re
import subprocess
import zipfile

# Verified on 2026-10-24; new builds require an explicit review of Apple releases
# and the runner image before adding them here. Build-number shape is not proof:
# Xcode 27.1 beta (27A9269) and macOS 27.2 RC (26B118) have no lowercase suffix.
# https://developer.apple.com/news/releases/?id=10152026a
# https://developer.apple.com/news/releases/
# https://github.com/actions/runner-images/blob/bf53d8b8e0ec75c9f9ef200efc8a4cf21ce128b6/images/macos/xcode-27-arm64-Readme.md
VERIFIED_TOOLCHAINS = {
    ("27A9275", "24A94232"): {"xcode": "27.1", "DTXcode": "2710", "sdk": "27.1"},
}
VERIFIED_MACOS_BUILDS = {"26A434"}  # macOS 27.0.1; xcode-27 image 20261012.0260.1


def check_macos_build(value):
    if value not in VERIFIED_MACOS_BUILDS:
        raise ValueError(f"macOS build {value!r} is not verified for release; review the allowlist before shipping")


def verified_toolchain(xcode_build, sdk_build):
    toolchain = VERIFIED_TOOLCHAINS.get((xcode_build, sdk_build))
    if toolchain is None:
        raise ValueError(f"Xcode/SDK builds {xcode_build!r}/{sdk_build!r} are not verified for release; "
                         "review the allowlist before shipping")
    return toolchain


def check_environment(os_build, xcode_output, sdk_version, sdk_build):
    check_macos_build(os_build)
    match = re.fullmatch(r"Xcode ([\d.]+)\s+Build version (\S+)", xcode_output.strip())
    if not match:
        raise ValueError("Unrecognized Xcode version output")
    toolchain = verified_toolchain(match[2], sdk_build)
    if (match[1], sdk_version) != (toolchain["xcode"], toolchain["sdk"]):
        raise ValueError("Xcode/iPhoneOS SDK versions do not match the verified release builds")
    return {"macOSBuild": os_build, "xcode": match[1], "xcodeBuild": match[2],
            "sdk": sdk_version, "sdkBuild": sdk_build}


def check_metadata(info):
    if info.get("CFBundleIdentifier") != "com.aiworkdeck.mobile.cn":
        raise ValueError("IPA does not contain the AI WorkDeck main app")
    if info.get("DTPlatformName") != "iphoneos":
        raise ValueError("IPA must target iPhoneOS, not a simulator")
    check_macos_build(info.get("BuildMachineOSBuild"))
    toolchain = verified_toolchain(info.get("DTXcodeBuild"), info.get("DTSDKBuild"))
    if (str(info.get("DTXcode", "")), info.get("DTSDKName")) != (
            toolchain["DTXcode"], "iphoneos" + toolchain["sdk"]):
        raise ValueError("IPA Xcode/iPhoneOS SDK versions do not match the verified release builds")
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
