import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    "next_build", Path(__file__).resolve().parents[1] / "asc-next-build.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def page(field, numbers, next_url=None):
    return {"data": [{"attributes": {field: str(n)}} for n in numbers],
            "links": {"next": next_url}}


class NextBuildTests(unittest.TestCase):
    def test_includes_upload_not_yet_visible_as_build(self):
        with patch.object(module.asc, "call", side_effect=[
            page("version", [29, 30]), page("cfBundleVersion", [30, 31])
        ]) as call:
            self.assertEqual(module.next_build_number("test", "app"), 32)
            self.assertEqual(call.call_args.args[2], "/apps/app/buildUploads?limit=200")

    def test_paginates_both_sources_and_ignores_non_numeric_versions(self):
        with patch.object(module.asc, "call", side_effect=[
            page("version", [29], "builds-page-2"),
            page("version", [40, "beta"]),
            page("cfBundleVersion", [31], "uploads-page-2"),
            page("cfBundleVersion", [41])
        ]) as call:
            self.assertEqual(module.next_build_number("test", "app"), 42)
            self.assertEqual([c.args[2] for c in call.call_args_list][1::2],
                             ["builds-page-2", "uploads-page-2"])

    def test_upload_query_error_does_not_reuse_a_number(self):
        with patch.object(module.asc, "call", side_effect=[
            page("version", [30]), {"ERROR": 503, "body": {"errors": []}}
        ]):
            with self.assertRaises(SystemExit):
                module.next_build_number("test", "app")


if __name__ == "__main__":
    unittest.main()
