#!/usr/bin/env python3
"""Copy App Review contact fields (name/phone/email) from the latest version that has them
into fastlane/metadata/review_information/*.txt, so a new version can be submitted from CI
without keeping personal contact data in the repo. Prints field names only, never values."""
import importlib.util, os, sys
here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("asc", os.path.join(here, "asc-listing.py"))
asc = importlib.util.module_from_spec(spec); spec.loader.exec_module(asc)
out = sys.argv[1]
FIELDS = {"contactFirstName": "first_name.txt", "contactLastName": "last_name.txt",
          "contactPhone": "phone_number.txt", "contactEmail": "email_address.txt"}
tok = asc.token_for()
vs = asc.call(tok, "GET", f"/apps/{asc.APP_ID}/appStoreVersions?limit=10")
asc.die_on_error(vs, "appStoreVersions")
for v in vs["data"]:
    r = asc.call(tok, "GET", f"/appStoreVersions/{v['id']}/appStoreReviewDetail")
    a = ((r or {}).get("data") or {}).get("attributes") or {}
    if all(a.get(k) for k in FIELDS):
        for k, fn in FIELDS.items():
            open(os.path.join(out, fn), "w").write(a[k])
        print(f"review contact copied from version {v['attributes'].get('versionString')}: {', '.join(FIELDS)}")
        break
else:
    sys.exit("no previous version with complete review contact information")
