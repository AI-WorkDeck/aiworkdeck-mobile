#!/usr/bin/env python3
"""下一个 build 号 = 该 App 在 ASC 上构建及上传预留编号中的最大值 +1。

用法：python scripts/asc-next-build.py   （env 同 asc-listing.py）

为什么不用 fastlane 的 latest_testflight_build_number：它只看「最新预发布版本」下的
构建，2026-09-02 它报 19 而 ASC 上已有 build 20，CI 用 20 上传被 altool 以
409 ENTITY_ERROR.RELATIONSHIP.INVALID.INVALID_STATE（buildUpload）拒掉。
"""
import importlib.util
import os

spec = importlib.util.spec_from_file_location(
    "asc", os.path.join(os.path.dirname(os.path.abspath(__file__)), "asc-listing.py"))
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)

def next_build_number(tok, app_id):
    nums = []
    # A received upload can remain absent from builds while Apple processes it.
    # Include reservations too, so a following release cannot reuse that number.
    for resource, field in (("builds", "version"), ("buildUploads", "cfBundleVersion")):
        path = f"/apps/{app_id}/{resource}?limit=200"
        while path:
            r = asc.call(tok, "GET", path)
            asc.die_on_error(r, f"读取 {resource}")
            nums += [int(b["attributes"][field]) for b in r["data"]
                     if str(b["attributes"].get(field, "")).isdigit()]
            path = (r.get("links") or {}).get("next")
    return max(nums, default=0) + 1


if __name__ == "__main__":
    print(next_build_number(asc.token_for(), asc.APP_ID))
