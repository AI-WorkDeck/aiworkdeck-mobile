#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Google Play Android Publisher v3 automation CLI for AI WorkDeck.

Supports:
  - upload: Upload a signed .aab and assign it to a Play track.
  - promote: Promote a versionCode from one Play track to another.
  - sync-skus: Sync and activate Google Play one-time products from contract/products.json.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable


REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_PACKAGE = "com.aiworkdeck.mobile"
DEFAULT_KEY_FILE = (
    Path.home()
    / ".local/share/aiworkdeck-ops/credentials/android/play-service-account.json"
)
DEFAULT_PRODUCTS_FILE = REPO_ROOT / "contract/products.json"
DEFAULT_NOTES_FILE = REPO_ROOT / "android/store/listing/en-US/release_notes.txt"
PUBLISHER_SCOPE = "https://www.googleapis.com/auth/androidpublisher"
API_BASE = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications"
UPLOAD_BASE = (
    "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications"
)


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def load_service_account(key_file: str | None) -> dict[str, Any]:
    """Load Google Play service account JSON from --key-file, env, or default path."""
    env_json = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON", "").strip()
    if not key_file and env_json:
        if env_json.startswith("{"):
            return json.loads(env_json)
        path = Path(env_json).expanduser()
        return json.loads(path.read_text(encoding="utf-8"))

    path = Path(key_file).expanduser() if key_file else DEFAULT_KEY_FILE
    if not path.is_file():
        raise FileNotFoundError(
            f"Service account key not found at {path}. Pass --key-file or set PLAY_SERVICE_ACCOUNT_JSON."
        )
    return json.loads(path.read_text(encoding="utf-8"))


def mint_access_token(sa: dict[str, Any]) -> str:
    """Exchange a signed RS256 JWT for a Google OAuth2 access token using openssl."""
    now = int(time.time())
    token_uri = sa.get("token_uri") or "https://oauth2.googleapis.com/token"
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": sa["client_email"],
        "scope": PUBLISHER_SCOPE,
        "aud": token_uri,
        "iat": now,
        "exp": now + 3600,
    }
    signing_input = (
        f"{_b64url(json.dumps(header, separators=(',', ':')).encode('utf-8'))}."
        f"{_b64url(json.dumps(claims, separators=(',', ':')).encode('utf-8'))}"
    ).encode("ascii")

    fd, pem_path = tempfile.mkstemp(prefix="play-sa-", suffix=".pem")
    try:
        os.chmod(pem_path, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(sa["private_key"])
        proc = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", pem_path],
            input=signing_input,
            capture_output=True,
            check=True,
        )
    finally:
        if os.path.exists(pem_path):
            os.unlink(pem_path)

    jwt_assertion = f"{signing_input.decode('ascii')}.{_b64url(proc.stdout)}"
    body = urllib.parse.urlencode(
        {
            "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
            "assertion": jwt_assertion,
        }
    ).encode("ascii")
    req = urllib.request.Request(
        token_uri,
        data=body,
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    return payload["access_token"]


class PlayClient:
    """Thin stdlib client for Google Play Android Publisher v3."""

    def __init__(self, package_name: str, token: str) -> None:
        self.package_name = package_name
        self.token = token

    def request_json(
        self,
        method: str,
        url: str,
        payload: dict[str, Any] | None = None,
        timeout: int = 60,
    ) -> dict[str, Any]:
        data = None
        headers = {"Authorization": f"Bearer {self.token}"}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json; charset=utf-8"
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                raw = resp.read()
                return json.loads(raw.decode("utf-8")) if raw else {}
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", errors="replace")
            raise RuntimeError(
                f"HTTP {err.code} {method} {url}: {detail}"
            ) from err

    def upload_binary(
        self, url: str, file_path: Path, timeout: int = 300
    ) -> dict[str, Any]:
        raw = file_path.read_bytes()
        req = urllib.request.Request(
            url,
            data=raw,
            headers={
                "Authorization": f"Bearer {self.token}",
                "Content-Type": "application/octet-stream",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=timeout) as resp:
                return json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", errors="replace")
            raise RuntimeError(f"HTTP {err.code} POST {url}: {detail}") from err

    def run_edit(
        self,
        fn: Callable[[str], dict[str, Any]],
        changes_not_sent_for_review: bool = False,
        dry_run: bool = False,
    ) -> dict[str, Any]:
        edit = self.request_json(
            "POST", f"{API_BASE}/{self.package_name}/edits", {}
        )
        edit_id = edit["id"]
        committed = False
        try:
            result = fn(edit_id)
            if not dry_run:
                suffix = (
                    "?changesNotSentForReview=true"
                    if changes_not_sent_for_review
                    else ""
                )
                commit_resp = self.request_json(
                    "POST",
                    f"{API_BASE}/{self.package_name}/edits/{edit_id}:commit{suffix}",
                )
                committed = True
                result["committedEditId"] = commit_resp.get("id", edit_id)
            return result
        finally:
            if not committed:
                try:
                    self.request_json(
                        "DELETE",
                        f"{API_BASE}/{self.package_name}/edits/{edit_id}",
                    )
                except Exception:
                    pass


def read_release_notes(notes_file: str | None) -> list[dict[str, str]] | None:
    path = Path(notes_file).expanduser() if notes_file else DEFAULT_NOTES_FILE
    if not path.is_file():
        if notes_file:
            raise FileNotFoundError(f"Release notes file not found: {path}")
        return None
    text = path.read_text(encoding="utf-8").strip()
    if not text:
        return None
    return [{"language": "en-US", "text": text}]


def cmd_upload(client: PlayClient, args: argparse.Namespace) -> None:
    aab_path = Path(args.aab).expanduser().resolve()
    if not aab_path.is_file():
        raise FileNotFoundError(f"AAB not found: {aab_path}")
    notes = read_release_notes(args.notes_file)

    def _work(edit_id: str) -> dict[str, Any]:
        bundle = client.upload_binary(
            f"{UPLOAD_BASE}/{client.package_name}/edits/{edit_id}/bundles?uploadType=media",
            aab_path,
        )
        version_code = str(bundle["versionCode"])
        release: dict[str, Any] = {
            "versionCodes": [version_code],
            "status": args.status,
        }
        if notes:
            release["releaseNotes"] = notes
        track_resp = client.request_json(
            "PUT",
            f"{API_BASE}/{client.package_name}/edits/{edit_id}/tracks/{args.track}",
            {"track": args.track, "releases": [release]},
        )
        return {
            "action": "upload",
            "packageName": client.package_name,
            "track": track_resp.get("track", args.track),
            "versionCode": int(version_code),
            "sha256": bundle.get("sha256"),
            "status": args.status,
            "dryRun": args.dry_run,
        }

    result = client.run_edit(
        _work,
        changes_not_sent_for_review=args.changes_not_sent_for_review,
        dry_run=args.dry_run,
    )
    print(json.dumps(result, indent=2, ensure_ascii=False))


def cmd_promote(client: PlayClient, args: argparse.Namespace) -> None:
    override_notes = read_release_notes(args.notes_file) if args.notes_file else None

    def _work(edit_id: str) -> dict[str, Any]:
        source = client.request_json(
            "GET",
            f"{API_BASE}/{client.package_name}/edits/{edit_id}/tracks/{args.from_track}",
        )
        releases = source.get("releases") or []
        chosen: dict[str, Any] | None = None
        target_vc = str(args.version_code) if args.version_code else None
        for rel in releases:
            vcs = [str(v) for v in (rel.get("versionCodes") or [])]
            if not vcs:
                continue
            if target_vc is None or target_vc in vcs:
                chosen = rel
                break
        if chosen is None and target_vc is None:
            raise RuntimeError(
                f"No release with versionCodes found on source track '{args.from_track}'"
            )

        version_codes = [target_vc] if target_vc else [str(v) for v in chosen["versionCodes"]]
        release: dict[str, Any] = {
            "versionCodes": version_codes,
            "status": args.status,
        }
        if args.rollout is not None:
            release["userFraction"] = args.rollout
        notes = override_notes or (chosen.get("releaseNotes") if chosen else None)
        if notes:
            release["releaseNotes"] = notes

        track_resp = client.request_json(
            "PUT",
            f"{API_BASE}/{client.package_name}/edits/{edit_id}/tracks/{args.to_track}",
            {"track": args.to_track, "releases": [release]},
        )
        return {
            "action": "promote",
            "packageName": client.package_name,
            "fromTrack": args.from_track,
            "toTrack": track_resp.get("track", args.to_track),
            "versionCodes": version_codes,
            "status": args.status,
            "dryRun": args.dry_run,
        }

    result = client.run_edit(
        _work,
        changes_not_sent_for_review=args.changes_not_sent_for_review,
        dry_run=args.dry_run,
    )
    print(json.dumps(result, indent=2, ensure_ascii=False))


def _format_usd_money(amount_cents: int) -> dict[str, Any]:
    units, cents = divmod(amount_cents, 100)
    return {
        "currencyCode": "USD",
        "units": str(units),
        "nanos": cents * 10_000_000,
    }


def _usd_label(amount_cents: int) -> str:
    if amount_cents % 100 == 0:
        return f"${amount_cents // 100}"
    return f"${amount_cents / 100:.2f}"


def cmd_sync_skus(client: PlayClient, args: argparse.Namespace) -> None:
    products_path = Path(args.products_file).expanduser()
    catalog = json.loads(products_path.read_text(encoding="utf-8"))
    gp_skus = catalog.get("googleplay") or []
    if not gp_skus:
        raise RuntimeError(f"No 'googleplay' products found in {products_path}")

    summary: list[dict[str, Any]] = []
    for item in gp_skus:
        product_id = item["productId"]
        amount_cents = int(item["amountCents"])
        base_price = _format_usd_money(amount_cents)
        usd_text = _usd_label(amount_cents)

        conv = client.request_json(
            "POST",
            f"{API_BASE}/{client.package_name}/pricing:convertRegionPrices",
            {"price": base_price},
        )
        region_version = (conv.get("regionVersion") or {}).get("version")
        if not region_version:
            raise RuntimeError(
                f"pricing:convertRegionPrices missing regionVersion for {product_id}: {conv}"
            )
        converted = conv.get("convertedRegionPrices") or {}
        regional_configs: list[dict[str, Any]] = []
        for region_code, entry in sorted(converted.items()):
            price_obj = entry.get("price")
            if price_obj:
                regional_configs.append(
                    {
                        "regionCode": region_code,
                        "availability": "AVAILABLE",
                        "price": price_obj,
                    }
                )
        if not any(cfg["regionCode"] == "US" for cfg in regional_configs):
            regional_configs.insert(
                0,
                {
                    "regionCode": "US",
                    "availability": "AVAILABLE",
                    "price": base_price,
                },
            )

        patch_body = {
            "packageName": client.package_name,
            "productId": product_id,
            "listings": [
                {
                    "languageCode": "en-US",
                    "title": f"{usd_text} AI WorkDeck Credits",
                    "description": (
                        f"Add {usd_text} USD of AI WorkDeck compute credits to your account."
                    ),
                }
            ],
            "purchaseOptions": [
                {
                    "purchaseOptionId": "buy",
                    "buyOption": {"legacyCompatible": True},
                    "regionalPricingAndAvailabilityConfigs": regional_configs,
                }
            ],
        }

        if args.dry_run:
            summary.append(
                {
                    "productId": product_id,
                    "amountCents": amount_cents,
                    "regionCount": len(regional_configs),
                    "regionVersion": region_version,
                    "dryRun": True,
                }
            )
            continue

        # Google Play v3 quirk: PATCH uses lowercase `onetimeproducts`,
        # while GET and :batchUpdateStates use camelCase `oneTimeProducts`.
        patch_query = urllib.parse.urlencode(
            {
                "allowMissing": "true",
                "regionsVersion.version": region_version,
                "updateMask": "listings,purchaseOptions",
            }
        )
        patched = client.request_json(
            "PATCH",
            f"{API_BASE}/{client.package_name}/onetimeproducts/{product_id}?{patch_query}",
            patch_body,
        )

        to_activate = [
            opt["purchaseOptionId"]
            for opt in (patched.get("purchaseOptions") or [])
            if opt.get("state") != "ACTIVE"
        ]
        if to_activate:
            client.request_json(
                "POST",
                f"{API_BASE}/{client.package_name}/oneTimeProducts/{product_id}/purchaseOptions:batchUpdateStates",
                {
                    "requests": [
                        {
                            "activatePurchaseOptionRequest": {
                                "packageName": client.package_name,
                                "productId": product_id,
                                "purchaseOptionId": opt_id,
                            }
                        }
                        for opt_id in to_activate
                    ]
                },
            )

        current = client.request_json(
            "GET",
            f"{API_BASE}/{client.package_name}/oneTimeProducts/{product_id}",
        )
        states = {
            opt.get("purchaseOptionId"): opt.get("state")
            for opt in (current.get("purchaseOptions") or [])
        }
        summary.append(
            {
                "productId": product_id,
                "amountCents": amount_cents,
                "regionCount": len(regional_configs),
                "purchaseOptionStates": states,
            }
        )

    print(
        json.dumps(
            {
                "action": "sync-skus",
                "packageName": client.package_name,
                "products": summary,
            },
            indent=2,
            ensure_ascii=False,
        )
    )


def build_parser() -> argparse.ArgumentParser:
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument(
        "--package",
        default=DEFAULT_PACKAGE,
        help=f"Android applicationId (default: {DEFAULT_PACKAGE})",
    )
    common.add_argument(
        "--key-file",
        default=None,
        help=f"Path to service account JSON (default: env PLAY_SERVICE_ACCOUNT_JSON or {DEFAULT_KEY_FILE})",
    )
    common.add_argument(
        "--dry-run",
        action="store_true",
        help="Validate without committing edits or mutating Play catalog",
    )

    parser = argparse.ArgumentParser(
        description="Google Play Android Publisher v3 CLI for AI WorkDeck."
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_upload = sub.add_parser(
        "upload", parents=[common], help="Upload an AAB and release it to a track"
    )
    p_upload.add_argument("--aab", required=True, help="Path to signed .aab file")
    p_upload.add_argument(
        "--track",
        default="internal",
        help="Target track: internal, alpha, beta, or production (default: internal)",
    )
    p_upload.add_argument(
        "--status",
        default="completed",
        choices=["completed", "draft", "halted", "inProgress"],
        help="Track release status (default: completed)",
    )
    p_upload.add_argument(
        "--notes-file",
        default=None,
        help=f"Optional en-US release notes file (default if exists: {DEFAULT_NOTES_FILE})",
    )
    p_upload.add_argument(
        "--changes-not-sent-for-review",
        action="store_true",
        help="Commit edit with changesNotSentForReview=true",
    )

    p_promote = sub.add_parser(
        "promote", parents=[common], help="Promote a release between Play tracks"
    )
    p_promote.add_argument(
        "--from-track",
        default="internal",
        help="Source track to inspect (default: internal)",
    )
    p_promote.add_argument(
        "--to-track",
        default="production",
        help="Destination track (default: production)",
    )
    p_promote.add_argument(
        "--version-code",
        type=int,
        default=None,
        help="Specific versionCode to promote (default: latest from --from-track)",
    )
    p_promote.add_argument(
        "--status",
        default="completed",
        choices=["completed", "draft", "halted", "inProgress"],
        help="Destination release status (default: completed)",
    )
    p_promote.add_argument(
        "--rollout",
        type=float,
        default=None,
        help="User fraction (0 < rollout < 1) when --status inProgress",
    )
    p_promote.add_argument(
        "--notes-file",
        default=None,
        help="Optional override release notes file",
    )
    p_promote.add_argument(
        "--changes-not-sent-for-review",
        action="store_true",
        help="Commit edit with changesNotSentForReview=true",
    )

    p_skus = sub.add_parser(
        "sync-skus",
        parents=[common],
        help="Create/update and activate Google Play SKUs from contract/products.json",
    )
    p_skus.add_argument(
        "--products-file",
        default=str(DEFAULT_PRODUCTS_FILE),
        help=f"Path to products.json (default: {DEFAULT_PRODUCTS_FILE})",
    )

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    sa = load_service_account(args.key_file)
    token = mint_access_token(sa)
    client = PlayClient(args.package, token)
    if args.command == "upload":
        cmd_upload(client, args)
    elif args.command == "promote":
        cmd_promote(client, args)
    elif args.command == "sync-skus":
        cmd_sync_skus(client, args)
    else:
        parser.error(f"Unknown command: {args.command}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
