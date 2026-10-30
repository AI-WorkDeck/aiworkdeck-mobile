import importlib.util
import json
import os
from pathlib import Path
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location("compatibility", Path(__file__).resolve().parents[1] / "check-ios-compatibility.py")
compatibility = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compatibility)


class CompatibilityGate(unittest.TestCase):
    def setUp(self):
        self.sha = "a" * 40
        self.run = {"id": 5, "run_attempt": 1, "head_sha": self.sha, "event": "push",
                    "path": ".github/workflows/ios-auth-check.yml", "status": "completed",
                    "conclusion": "success", "html_url": "https://github.com/example/actions/runs/5"}
        self.jobs = [{"name": f"simulator ({family})", "conclusion": "success"}
                     for family in compatibility.FAMILIES]

    def test_exact_commit_with_all_three_devices_can_upload(self):
        self.assertEqual(compatibility.check_run(self.run, self.jobs, self.sha), self.run["html_url"])

    def test_old_commit_other_workflow_and_pr_merge_checks_cannot_upload(self):
        for change in ({"head_sha": "b" * 40}, {"path": ".github/workflows/android.yml"},
                       {"event": "pull_request"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                compatibility.check_run({**self.run, **change}, self.jobs, self.sha)

    def test_failed_cancelled_pending_and_skipped_device_checks_block_upload(self):
        for index in range(3):
            for result in ("failure", "cancelled", "skipped", None):
                jobs = [dict(job) for job in self.jobs]
                jobs[index]["conclusion"] = result
                with self.subTest(device=index, result=result), self.assertRaises(ValueError):
                    compatibility.check_run(self.run, jobs, self.sha)

    def test_missing_or_duplicate_device_check_blocks_upload(self):
        for jobs in (self.jobs[:2], self.jobs + [self.jobs[0]]):
            with self.assertRaises(ValueError):
                compatibility.check_run(self.run, jobs, self.sha)

    def test_upload_workflow_must_finish_native_jobs_before_signing(self):
        run = {**self.run, "path": ".github/workflows/appstore-build.yml",
               "status": "in_progress", "conclusion": None}
        jobs = [{**job, "name": "compatibility / " + job["name"]} for job in self.jobs]
        self.assertEqual(compatibility.check_run(run, jobs, self.sha, uploading=True), self.run["html_url"])
        jobs[-1]["conclusion"] = None
        with self.assertRaises(ValueError):
            compatibility.check_run(run, jobs, self.sha, uploading=True)

    def test_latest_failed_attempt_cannot_reuse_an_older_green_run(self):
        newest = {**self.run, "id": 6, "conclusion": "failure"}
        with patch.dict(os.environ, {}, clear=True), patch.object(compatibility, "command",
                side_effect=["", self.sha, json.dumps([{"jobs": self.jobs}])]), patch.object(
                compatibility, "api", return_value={"workflow_runs": [self.run, newest]}):
            with self.assertRaisesRegex(ValueError, "Latest compatibility run"):
                compatibility.main()

    def test_newer_pr_does_not_hide_successful_exact_source_run(self):
        pr = {**self.run, "id": 6, "event": "pull_request"}
        with patch.dict(os.environ, {}, clear=True), patch.object(compatibility, "command",
                side_effect=["", self.sha, json.dumps([{"jobs": self.jobs}])]) as command, patch.object(
                compatibility, "api", return_value={"workflow_runs": [self.run, pr]}):
            compatibility.main()
            self.assertIn("/runs/5/attempts/1/jobs", command.call_args.args[-1])

    def test_pr_only_results_are_not_exact_source_evidence(self):
        pr = {**self.run, "event": "pull_request"}
        with patch.dict(os.environ, {}, clear=True), patch.object(compatibility, "command",
                side_effect=["", self.sha]), patch.object(
                compatibility, "api", return_value={"workflow_runs": [pr]}):
            with self.assertRaisesRegex(ValueError, "No compatibility run"):
                compatibility.main()

    def test_newest_exact_failure_is_not_hidden_by_successful_pr(self):
        failed = {**self.run, "id": 6, "event": "workflow_dispatch", "conclusion": "failure"}
        pr = {**self.run, "id": 7, "event": "pull_request"}
        with patch.dict(os.environ, {}, clear=True), patch.object(compatibility, "command",
                side_effect=["", self.sha, json.dumps([{"jobs": self.jobs}])]) as command, patch.object(
                compatibility, "api", return_value={"workflow_runs": [self.run, failed, pr]}):
            with self.assertRaisesRegex(ValueError, "Latest compatibility run"):
                compatibility.main()
            self.assertIn("/runs/6/attempts/1/jobs", command.call_args.args[-1])

    def test_uncommitted_source_stops_before_reading_remote_results(self):
        with patch.object(compatibility, "command", return_value=" M ios/Sources/App.swift"), patch.object(
                compatibility, "api") as remote:
            with self.assertRaisesRegex(ValueError, "Commit all source"):
                compatibility.main()
            remote.assert_not_called()

    def test_missing_exact_commit_checks_stop_upload(self):
        with patch.dict(os.environ, {}, clear=True), patch.object(compatibility, "command",
                side_effect=["", self.sha]), patch.object(compatibility, "api", return_value={"workflow_runs": []}):
            with self.assertRaisesRegex(ValueError, "No compatibility run"):
                compatibility.main()

    def test_pending_or_failed_run_blocks_even_when_jobs_are_green(self):
        for change in ({"status": "in_progress", "conclusion": None}, {"conclusion": "failure"}):
            with self.subTest(change=change), self.assertRaises(ValueError):
                compatibility.check_run({**self.run, **change}, self.jobs, self.sha)

    def test_rerun_reads_only_current_attempt_jobs(self):
        rerun = {**self.run, "run_attempt": 2}
        with patch.dict(os.environ, {}, clear=True), patch.object(compatibility, "command",
                side_effect=["", self.sha, json.dumps([{"jobs": self.jobs[:2]}])]) as command, patch.object(
                compatibility, "api", return_value={"workflow_runs": [rerun]}):
            with self.assertRaises(ValueError):
                compatibility.main()
            self.assertIn("/attempts/2/jobs", command.call_args.args[-1])


if __name__ == "__main__":
    unittest.main()
