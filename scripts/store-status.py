#!/usr/bin/env python3
"""Read-only store status: App Store Connect versions/builds and Google Play tracks.
Never uploads, edits or submits. Play: opens an edit only to read tracks, then deletes it (never commits).
env: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_PATH (App Store); PLAY_SERVICE_ACCOUNT_JSON (Google Play, optional).
"""
import importlib.util, json, os, sys, time, urllib.parse, urllib.request
import jwt

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("asc", os.path.join(here, "asc-listing.py"))
asc = importlib.util.module_from_spec(spec); spec.loader.exec_module(asc)

def appstore():
    tok = asc.token_for()
    print("## App Store Connect (app %s)\n" % asc.APP_ID)
    r = asc.call(tok, "GET", f"/apps/{asc.APP_ID}/appStoreVersions?limit=8")
    asc.die_on_error(r, "appStoreVersions")
    print("| version | platform | state | created |\n|---|---|---|---|")
    for v in r["data"]:
        a = v["attributes"]
        print(f"| {a.get('versionString')} | {a.get('platform')} | {a.get('appStoreState') or a.get('appVersionState')} | {(a.get('createdDate') or '')[:10]} |")
    r = asc.call(tok, "GET", f"/builds?filter[app]={asc.APP_ID}&sort=-uploadedDate&limit=8&include=preReleaseVersion")
    asc.die_on_error(r, "builds")
    pre = {i["id"]: i["attributes"].get("version") for i in r.get("included", []) if i["type"] == "preReleaseVersions"}
    print("\n| marketing version | build | processing | uploaded |\n|---|---|---|---|")
    for b in r["data"]:
        a = b["attributes"]; pv = (b.get("relationships", {}).get("preReleaseVersion", {}).get("data") or {}).get("id")
        print(f"| {pre.get(pv, '?')} | {a.get('version')} | {a.get('processingState')} | {(a.get('uploadedDate') or '')[:16]} |")

def play(pkg="com.aiworkdeck.mobile"):
    raw = os.environ.get("PLAY_SERVICE_ACCOUNT_JSON")
    if not raw:
        print("\n## Google Play\n\nPLAY_SERVICE_ACCOUNT_JSON not set"); return
    sa = json.loads(raw); now = int(time.time())
    assertion = jwt.encode({"iss": sa["client_email"], "scope": "https://www.googleapis.com/auth/androidpublisher",
                            "aud": sa["token_uri"], "iat": now, "exp": now + 600}, sa["private_key"], algorithm="RS256")
    body = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer", "assertion": assertion}).encode()
    token = json.load(urllib.request.urlopen(urllib.request.Request(sa["token_uri"], data=body)))["access_token"]
    base = f"https://androidpublisher.googleapis.com/androidpublisher/v3/applications/{pkg}/edits"
    def req(method, url):
        r = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {token}"}, data=b"" if method == "POST" else None)
        with urllib.request.urlopen(r) as resp:
            t = resp.read(); return json.loads(t) if t else {}
    edit = req("POST", base)["id"]
    try:
        tracks = req("GET", f"{base}/{edit}/tracks").get("tracks", [])
        print(f"\n## Google Play ({pkg})\n\n| track | status | versionCodes | name |\n|---|---|---|---|")
        for t in tracks:
            for rel in t.get("releases", []):
                print(f"| {t['track']} | {rel.get('status')} | {','.join(rel.get('versionCodes', []))} | {rel.get('name', '')} |")
    finally:
        req("DELETE", f"{base}/{edit}")  # read-only: discard the edit

if __name__ == "__main__":
    appstore()
    try: play()
    except Exception as e: print(f"\nGoogle Play query failed: {type(e).__name__}: {e}")
