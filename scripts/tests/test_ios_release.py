import importlib.util
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parents[1] / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load("ios_release", "check-ios-release.py")
simulator = load("ios_simulator", "create-ios-ci-simulator.py")


class ReleaseChecks(unittest.TestCase):
    def test_final_27_1_environment_is_accepted(self):
        result = release.check_environment("26A434", "Xcode 27.1\nBuild version 27A9275", "27.1", "24A94232")
        self.assertEqual(result["xcodeBuild"], "27A9275")

    def test_old_or_prerelease_environment_cannot_ship(self):
        final = ["26A434", "Xcode 27.1\nBuild version 27A9275", "27.1", "24A94232"]
        for index, bad in [(0, "26A5421a"), (1, "Xcode 26.6\nBuild version 17F113"),
                           (1, "Xcode 27.2\nBuild version 27B5028f"), (2, "27.0"),
                           (2, "27.1 beta"), (3, "24A94232a")]:
            args = final.copy(); args[index] = bad
            with self.subTest(value=bad), self.assertRaises(ValueError):
                release.check_environment(*args)

    def metadata(self):
        return {"CFBundleIdentifier": "com.aiworkdeck.mobile.cn", "DTPlatformName": "iphoneos",
                "DTXcode": "2710", "DTXcodeBuild": "27A9275", "DTSDKName": "iphoneos27.1",
                "DTSDKBuild": "24A94232", "BuildMachineOSBuild": "26A434"}

    def test_ipa_reads_main_app_not_embedded_extensions(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "test.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Workdeck.app/Info.plist", plistlib.dumps(self.metadata()))
                archive.writestr("Payload/Workdeck.app/Watch/Watch.app/Info.plist", plistlib.dumps({}))
            self.assertEqual(release.check_ipa(path)["DTSDKName"], "iphoneos27.1")

    def test_wrong_or_older_built_app_is_rejected_even_on_new_host(self):
        for key, bad in [("DTXcode", "2660"), ("DTXcode", None), ("DTSDKName", "iphoneos26.6"),
                         ("DTSDKName", "iphonesimulator27.1"), ("DTSDKBuild", "24A123a"),
                         ("DTPlatformName", "iphonesimulator"), ("BuildMachineOSBuild", "26A5421a"),
                         ("DTXcodeBuild", "27B5028f"), ("CFBundleIdentifier", "other.app")]:
            info = self.metadata(); info[key] = bad
            with self.subTest(key=key, value=bad), self.assertRaises(ValueError):
                release.check_metadata(info)

    def test_suffix_free_beta_rc_and_unknown_toolchains_cannot_ship(self):
        # Apple released these beta/RC Xcode builds without a lowercase suffix.
        # The beta case keeps the approved SDK to isolate the Xcode rejection.
        for xcode, xcode_metadata, xcode_build, sdk, sdk_build in [
            ("27.1", "2710", "27A9269", "27.1", "24A94232"),
            ("27.2", "2720", "27B48", "27.2", "24B113"),
            ("27.1", "2710", "27A9276", "27.1", "24A94232"),
            ("27.1", "2710", "27A9275", "27.1", "24A94233"),
        ]:
            with self.subTest(xcode_build=xcode_build, sdk_build=sdk_build):
                with self.assertRaisesRegex(ValueError, "not verified for release"):
                    release.check_environment("26A434", f"Xcode {xcode}\nBuild version {xcode_build}", sdk, sdk_build)
                info = self.metadata()
                info.update(DTXcode=xcode_metadata, DTXcodeBuild=xcode_build,
                            DTSDKName="iphoneos" + sdk, DTSDKBuild=sdk_build)
                with self.assertRaisesRegex(ValueError, "not verified for release"):
                    release.check_metadata(info)

    def test_suffix_free_rc_and_unverified_macos_cannot_ship(self):
        for build in ("26B118", "26A435", None):
            with self.subTest(build=build):
                with self.assertRaisesRegex(ValueError, "macOS build.*not verified"):
                    release.check_environment(build, "Xcode 27.1\nBuild version 27A9275", "27.1", "24A94232")
                info = self.metadata(); info["BuildMachineOSBuild"] = build
                with self.assertRaisesRegex(ValueError, "macOS build.*not verified"):
                    release.check_metadata(info)

    def test_known_builds_with_mismatched_versions_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "versions do not match"):
            release.check_environment("26A434", "Xcode 27.2\nBuild version 27A9275", "27.1", "24A94232")
        for key, value in (("DTXcode", "2720"), ("DTSDKName", "iphoneos27.2")):
            info = self.metadata(); info[key] = value
            with self.subTest(key=key), self.assertRaisesRegex(ValueError, "versions do not match"):
                release.check_metadata(info)

    def test_unverified_ipa_exits_nonzero_before_fastlane_can_upload(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "beta.ipa"
            info = self.metadata(); info["DTXcodeBuild"] = "27A9269"
            with zipfile.ZipFile(path, "w") as archive:
                archive.writestr("Payload/Workdeck.app/Info.plist", plistlib.dumps(info))
            result = subprocess.run([sys.executable, release.__file__, "ipa", str(path)],
                                    capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("not verified for release", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_ambiguous_ipa_cannot_ship(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "test.ipa"
            with zipfile.ZipFile(path, "w") as archive:
                for name in ("First", "Second"):
                    archive.writestr(f"Payload/{name}.app/Info.plist", plistlib.dumps(self.metadata()))
            with self.assertRaises(ValueError):
                release.check_ipa(path)


class SimulatorSelection(unittest.TestCase):
    def runtimes(self):
        return [
            {"identifier": "ios27", "version": "27.0", "platform": "iOS", "isAvailable": True,
             "buildversion": "24A428", "supportedDeviceTypes": [
                 {"name": "iPhone 18 Pro", "identifier": "pro"},
                 {"name": "iPhone 18 Pro Max", "identifier": "max"}]},
            {"identifier": "ios271", "version": "27.1", "platform": "iOS", "isAvailable": True,
             "buildversion": "24A94232", "supportedDeviceTypes": [
                 {"name": "iPhone Duo", "identifier": "duo"}]}
        ]

    def test_regular_phone_uses_compatible_runtime_and_keeps_pro_max_coverage(self):
        runtime, device = simulator.select_device(self.runtimes(), "iphone")
        self.assertEqual((runtime["identifier"], device["identifier"]), ("ios27", "max"))

    def test_duo_uses_27_1_runtime(self):
        runtime, device = simulator.select_device(self.runtimes(), "duo")
        self.assertEqual((runtime["identifier"], device["identifier"]), ("ios271", "duo"))

    def test_missing_unavailable_or_beta_duo_never_falls_back_to_iphone(self):
        for change in ({"isAvailable": False}, {"buildversion": "24A94232a"}, {"supportedDeviceTypes": []}):
            runtimes = self.runtimes(); runtimes[1].update(change)
            with self.subTest(change=change), self.assertRaises(ValueError):
                simulator.select_device(runtimes, "duo")


if __name__ == "__main__":
    unittest.main()
