#!/usr/bin/env python3
"""Require successful native iPhone/iPhone-large/Duo checks before uploading iOS."""
import json
import os
from pathlib import Path
import subprocess


REPOSITORY = "AI-WorkDeck/aiworkdeck-mobile"
FAMILIES = ("iphone", "iphone-large", "duo")
ROOT = Path(__file__).resolve().parents[1]


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def api(endpoint):
    return json.loads(command("gh", "api", endpoint))


def check_run(run, jobs, sha, *, uploading=False):
    expected = "appstore-build.yml" if uploading else "ios-auth-check.yml"
    if run.get("head_sha") != sha:
        raise ValueError("Compatibility checks belong to another commit")
    if run.get("path", "").split("@")[0] != f".github/workflows/{expected}":
        raise ValueError("Compatibility checks came from another workflow")
    # PR head_sha identifies the branch, while checkout normally tests a merge ref.
    # Require a push or explicit dispatch that tested precisely the upload source.
    if run.get("event") not in ("push", "workflow_dispatch"):
        raise ValueError("Compatibility checks must test the exact commit, not a PR merge ref")
    if not uploading and (run.get("status") != "completed" or run.get("conclusion") != "success"):
        raise ValueError("Latest compatibility run has not completed successfully")
    prefix = "compatibility / " if uploading else ""
    for family in FAMILIES:
        name = f"{prefix}simulator ({family})"
        matching = [job for job in jobs if job.get("name") == name]
        if len(matching) != 1 or matching[0].get("conclusion") != "success":
            raise ValueError(f"Missing successful compatibility job: {name}")
    return run["html_url"]


def main():
    if command("git", "status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("Commit all source changes before checking the release candidate")
    sha = command("git", "rev-parse", "HEAD")
    uploading = os.environ.get("GITHUB_ACTIONS") == "true"
    if uploading:
        run_id = os.environ.get("GITHUB_RUN_ID", "")
        if not run_id.isdigit():
            raise ValueError("Missing current Actions run ID")
        run = api(f"repos/{REPOSITORY}/actions/runs/{run_id}")
    else:
        response = api(f"repos/{REPOSITORY}/actions/workflows/ios-auth-check.yml/runs?head_sha={sha}&per_page=100")
        # A PR's head SHA names this branch, but its checkout tests a merge ref.
        # Select among exact-source events before choosing the latest attempt.
        runs = [run for run in response.get("workflow_runs", [])
                if run.get("event") in ("push", "workflow_dispatch")]
        if not runs:
            raise ValueError("No compatibility run for this commit; run ios-auth-check before uploading")
        # Never reuse an older green result after a newer failed/incomplete run.
        run = max(runs, key=lambda item: (item["id"], item.get("run_attempt", 1)))
    pages = json.loads(command("gh", "api", "--paginate", "--slurp",
                               f"repos/{REPOSITORY}/actions/runs/{run['id']}/attempts/{run.get('run_attempt', 1)}/jobs?per_page=100"))
    jobs = [job for page in pages for job in page["jobs"]]
    url = check_run(run, jobs, sha, uploading=uploading)
    print(f"iOS compatibility passed for {sha}: {url}")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, subprocess.CalledProcessError) as error:
        raise SystemExit(f"iOS upload blocked: {error}")
