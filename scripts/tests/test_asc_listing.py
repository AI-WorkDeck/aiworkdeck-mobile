import contextlib
import importlib.util
import io
from pathlib import Path
import unittest
from unittest.mock import mock_open, patch


spec = importlib.util.spec_from_file_location(
    "asc_listing", Path(__file__).resolve().parents[1] / "asc-listing.py")
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)


def info(identifier, **attributes):
    return {"type": "appInfos", "id": identifier, "attributes": attributes}


# Only the observed states and ordering are retained; IDs are synthetic.
LIVE = info("live", appStoreState="READY_FOR_SALE", state="READY_FOR_DISTRIBUTION")
REJECTED = info("editable", appStoreState="DEVELOPER_REJECTED", state="DEVELOPER_REJECTED")


class AppInfoTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.object(asc.urllib.request, "urlopen",
                                      side_effect=AssertionError("offline test")))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def test_developer_rejected_is_selected_regardless_of_response_order(self):
        for records in ([LIVE, REJECTED], [REJECTED, LIVE]):
            with self.subTest(records=records), patch.object(asc, "call", return_value={"data": records}):
                self.assertEqual(asc.app_info_id("test", "app"), "editable")

    def test_current_and_legacy_state_fields(self):
        for field in ("state", "appStoreState"):
            for state in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED"):
                with self.subTest(field=field, state=state), patch.object(asc, "call", return_value={
                    "data": [LIVE, info("editable", **{field: state})]
                }):
                    self.assertEqual(asc.app_info_id("test", "app"), "editable")

    def test_prepare_for_submission_keeps_priority(self):
        with patch.object(asc, "call", return_value={"data": [
            REJECTED, info("draft", state="PREPARE_FOR_SUBMISSION")
        ]}):
            self.assertEqual(asc.app_info_id("test", "app"), "draft")

    def test_no_editable_info_fails_closed(self):
        cases = [[], [LIVE], [info("unknown")]]
        for state in ("WAITING_FOR_REVIEW", "IN_REVIEW", "PENDING_DEVELOPER_RELEASE",
                      "READY_FOR_DISTRIBUTION", "FUTURE_STATE"):
            # A present current state must not be overridden by a stale legacy field.
            cases.append([info("locked", state=state, appStoreState="PREPARE_FOR_SUBMISSION")])
        for records in cases:
            with self.subTest(records=records), patch.object(asc, "call", return_value={"data": records}):
                with self.assertRaisesRegex(SystemExit, "可编辑.*appInfo"):
                    asc.app_info_id("test", "app")

    def test_api_error_is_not_treated_as_an_editable_record(self):
        with patch.object(asc, "call", return_value={"ERROR": 503, "body": {"errors": []}}):
            with self.assertRaisesRegex(SystemExit, "HTTP 503"):
                asc.app_info_id("test", "app")

    def test_text_updates_or_creates_localization_on_editable_info(self):
        for exists in (True, False):
            def respond(tok, method, path, body=None):
                if path == "/apps/app/appStoreVersions?limit=10":
                    return {"data": [{"id": "version", "attributes": {"appStoreState": "DEVELOPER_REJECTED"}}]}
                if path == "/apps/app/appInfos":
                    return {"data": [LIVE, REJECTED]}
                if method == "GET":
                    self.assertEqual(path, "/appInfos/editable/appInfoLocalizations?limit=50")
                    return {"data": [{"id": "editable-en", "attributes": {"locale": "en-US"}}] if exists else []}
                return {}

            with self.subTest(exists=exists), patch.object(asc, "call", side_effect=respond) as call, \
                    patch.object(asc, "read_locale_dir", return_value={"en-US": {
                        "name.txt": "Example", "subtitle.txt": "Example subtitle",
                        "privacy_url.txt": "https://example.invalid/privacy",
                    }}):
                asc.cmd_text("test", "app")
                args = call.call_args.args
                self.assertEqual(args[1:3], ("PATCH", "/appInfoLocalizations/editable-en") if exists
                                 else ("POST", "/appInfoLocalizations"))
                data = args[3]["data"]
                if not exists:
                    self.assertEqual(data["relationships"]["appInfo"]["data"]["id"], "editable")
                self.assertEqual(data["attributes"]["name"], "Example")

    def test_rating_and_category_write_only_to_editable_info(self):
        for command, path in ((asc.cmd_rating, "/ageRatingDeclarations/editable"),
                              (asc.cmd_category, "/appInfos/editable")):
            with self.subTest(command=command.__name__), \
                    patch.object(asc, "call", side_effect=[{"data": [LIVE, REJECTED]}, {}]) as call, \
                    patch.object(asc.os.path, "exists", return_value=True), \
                    patch("builtins.open", mock_open(read_data="PRODUCTIVITY")):
                command("test", "app")
                self.assertEqual(call.call_args.args[1:3], ("PATCH", path))

    def test_all_app_info_writers_stop_before_any_write_when_live_only(self):
        for command in (asc.cmd_text, asc.cmd_category, asc.cmd_rating):
            with self.subTest(command=command.__name__), \
                    patch.object(asc, "version", return_value={"id": "version"}), \
                    patch.object(asc, "call", return_value={"data": [LIVE]}) as call:
                with self.assertRaises(SystemExit):
                    command("test", "app")
                self.assertEqual([c.args[1] for c in call.call_args_list], ["GET"])

    def test_status_can_still_read_live_only_app(self):
        def respond(tok, method, path, body=None):
            self.assertEqual(method, "GET")
            if path == "/apps/app":
                return {"data": {"attributes": {"name": "Example", "bundleId": "invalid.example.app"}}}
            if path == "/apps/app/appInfos":
                return {"data": [LIVE]}
            if path.endswith("ageRatingDeclaration"):
                return {"data": {"attributes": {}}}
            if "appStoreVersionLocalizations" in path:
                return {"data": []}
            return {"data": None}

        with patch.object(asc, "call", side_effect=respond), patch.object(asc, "version", return_value={
            "id": "live-version", "attributes": {"versionString": "1.0", "appStoreState": "READY_FOR_SALE"}
        }):
            asc.cmd_status("test", "app")


if __name__ == "__main__":
    unittest.main()


def ver(identifier, version_string, state):
    return {"id": identifier, "attributes": {"versionString": version_string, "appStoreState": state}}


class WithdrawTests(unittest.TestCase):
    def setUp(self):
        self.enterContext(patch.object(asc.urllib.request, "urlopen",
                                      side_effect=AssertionError("offline test")))
        self.enterContext(contextlib.redirect_stdout(io.StringIO()))

    def run_withdraw(self, versions, expected="1.12.3", confirmed=True, after=None):
        """versions: list returned before the cancel; after: list returned once it is processed."""
        cancelled = []

        def respond(tok, method, path, body=None):
            if path.startswith("/apps/app/appStoreVersions"):
                return {"data": after if cancelled and after is not None else versions}
            if path.startswith("/apps/app/reviewSubmissions"):
                self.assertIn("IN_REVIEW", path)
                return {"data": [{"id": "sub"}]}
            if method == "PATCH":
                self.assertEqual(path, "/reviewSubmissions/sub")
                self.assertEqual(body["data"]["attributes"], {"canceled": True})
                cancelled.append(path)
                return {}
            self.fail(f"unexpected {method} {path}")

        with patch.object(asc, "call", side_effect=respond):
            asc.cmd_withdraw("tok", "app", expected, confirmed, wait=30, sleep=lambda s: None)
        return cancelled

    def test_cancels_matching_version_and_waits_until_editable(self):
        cancelled = self.run_withdraw([ver("v", "1.12.3", "IN_REVIEW")],
                                      after=[ver("v", "1.12.3", "DEVELOPER_REJECTED")])
        self.assertEqual(cancelled, ["/reviewSubmissions/sub"])

    def test_refuses_a_different_version_in_review(self):
        with self.assertRaisesRegex(SystemExit, "不是 1.12.3"):
            self.run_withdraw([ver("v", "1.12.4", "WAITING_FOR_REVIEW")])

    def test_dry_run_and_nothing_in_review_do_not_cancel(self):
        self.assertEqual(self.run_withdraw([ver("v", "1.12.3", "IN_REVIEW")], confirmed=False), [])
        self.assertEqual(self.run_withdraw([ver("v", "1.12.3", "READY_FOR_SALE")]), [])

    def test_stops_when_version_never_becomes_editable(self):
        with self.assertRaisesRegex(SystemExit, "仍是 IN_REVIEW"):
            self.run_withdraw([ver("v", "1.12.3", "IN_REVIEW")])
