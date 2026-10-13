#!/usr/bin/env python3
"""上架前那几项 deliver 管不到的 App Store Connect 设置。

fastlane 的 upload_to_app_store 负责二进制、文案、截图；剩下这些它要么没有
对应参数、要么参数形状跟不上 Apple 2026 年改版后的问卷，只能直接打 API：

  setversion    版本号对齐 ios/project.yml；加 auto 改成过审自动上架
  text          上架文案（fastlane/metadata/<locale>/*.txt → ASC）
  category      主/次类目（读 metadata/*_category.txt）
  review        审核联系信息与演示账号（读 metadata/review_information/）
  screenshots   上传截图（读 fastlane/screenshots/<locale>/，6.9 吋 1320x2868）
  watch-screenshots <目录> 上传独立 Watch 截图（416x496，按 locale 分目录）
  attach <build> 把已上传的构建挂到版本上（构建号，如 13）
  submit        提交审核。对外动作，要再打一次 --yes 才真发
  rating        年龄分级问卷（全部答「无」）
  contentrights 内容版权声明（不含第三方内容）
  price         价格表设为免费
  availability  上架区域（全球所有区）
  status        只读：把提审前的必填项逐条列出来，缺哪项一目了然

2026-09-05 起 iOS 只剩这一个 App（另一条 App 记录已删，dev-board#445/#446），
所以这里写死一个 App ID，不再带 flavor 参数。

用法（凭据从 fastlane/.env 读，见 5-Tech/EXTERNAL_SERVICES.md §6）：

    set -a; . fastlane/.env; set +a
    .venv/bin/python scripts/asc-listing.py status
    .venv/bin/python scripts/asc-listing.py rating

年龄分级的字段类型 Apple 改过不止一次（2026 版把 messagingAndChat、gambling
等一批从枚举改成了布尔）。这里不写死类型表：先一律按枚举 "NONE" 提交，拿
ENTITY_ERROR.ATTRIBUTE.TYPE 的报错把该改布尔的挑出来再提交一次。Apple 下次
再改，这段不用跟着改。
"""

import base64
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request

import jwt

BASE = "https://api.appstoreconnect.apple.com/v1"
BASE_V2 = "https://api.appstoreconnect.apple.com/v2"

# 北京京微资易（Team 8WKHZVR2W8）。全球上架，iOS 唯一的一条 App 记录。
APP_ID = "6803309103"
ENV_KEYS = ("ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH")

# 年龄分级问卷。这个 App 没有任何一项受限内容，全答「无」。
# 值只是初始猜测，布尔字段会被下面的类型协商自动改成 False。
RATING_FIELDS = [
    "advertising", "alcoholTobaccoOrDrugUseOrReferences", "contests", "gambling",
    "gamblingSimulated", "gunsOrOtherWeapons", "healthOrWellnessTopics", "lootBox",
    "medicalOrTreatmentInformation", "messagingAndChat", "parentalControls",
    "profanityOrCrudeHumor", "ageAssurance", "sexualContentGraphicAndNudity",
    "sexualContentOrNudity", "socialMedia", "socialMediaAgeRestricted",
    "horrorOrFearThemes", "matureOrSuggestiveThemes", "unrestrictedWebAccess",
    "userGeneratedContent", "violenceCartoonOrFantasy",
    "violenceRealisticProlongedGraphicOrSadistic", "violenceRealistic",
]


def token(kid, iss, key_path):
    key = open(os.path.expanduser(key_path)).read()
    payload = {"iss": iss, "iat": int(time.time()), "exp": int(time.time()) + 1200,
               "aud": "appstoreconnect-v1"}
    return jwt.encode(payload, key, algorithm="ES256", headers={"kid": kid, "typ": "JWT"})


def token_for():
    missing = [k for k in ENV_KEYS if not os.environ.get(k)]
    if missing:
        sys.exit(f"缺少环境变量 {', '.join(missing)}——先 `set -a; . fastlane/.env; set +a`")
    return token(*(os.environ[k] for k in ENV_KEYS))


def call(tok, method, path, body=None):
    url = path if path.startswith("http") else BASE + path
    req = urllib.request.Request(
        url, method=method,
        headers={"Authorization": f"Bearer {tok}", "Content-Type": "application/json"},
        data=json.dumps(body).encode() if body is not None else None)
    try:
        raw = urllib.request.urlopen(req).read()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return {"ERROR": e.code, "body": json.loads(raw)}
        except ValueError:
            return {"ERROR": e.code, "body": raw.decode()[:500]}


def errors_of(resp):
    if "ERROR" not in resp:
        return []
    body = resp["body"]
    return body.get("errors", []) if isinstance(body, dict) else []


def die_on_error(resp, what):
    for e in errors_of(resp):
        print(f"  ! {e.get('code')} {e.get('detail')}", file=sys.stderr)
    if "ERROR" in resp:
        sys.exit(f"{what} 失败（HTTP {resp['ERROR']}）")
    return resp


# ---------------------------------------------------------------- 读取

def app_info_id(tok, app_id):
    """已上架的 App 有两条 appInfo：在售那条和随新版本出现的可编辑那条。
    往在售那条加本地化会 409「cannot be created in current state」，所以优先取可编辑的。"""
    r = call(tok, "GET", f"/apps/{app_id}/appInfos")
    die_on_error(r, "读取 appInfos")
    for i in r["data"]:
        if i["attributes"].get("appStoreState") == "PREPARE_FOR_SUBMISSION":
            return i["id"]
    return r["data"][0]["id"]


def version(tok, app_id):
    """当前那条可编辑的版本记录。已提审/已上架的版本不在这里改。"""
    r = call(tok, "GET", f"/apps/{app_id}/appStoreVersions?limit=10")
    die_on_error(r, "读取 appStoreVersions")
    editable = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                "METADATA_REJECTED", "INVALID_BINARY"}
    for v in r["data"]:
        if v["attributes"]["appStoreState"] in editable:
            return v
    return r["data"][0] if r["data"] else None


# ---------------------------------------------------------------- 动作

def cmd_rating(tok, app_id):
    decl_id = app_info_id(tok, app_id)   # ageRatingDeclaration 与 appInfo 同 id
    attrs = {f: "NONE" for f in RATING_FIELDS}

    for attempt in range(3):
        body = {"data": {"type": "ageRatingDeclarations", "id": decl_id, "attributes": attrs}}
        r = call(tok, "PATCH", f"/ageRatingDeclarations/{decl_id}", body)
        if "ERROR" not in r:
            print(f"年龄分级已提交（{len(attrs)} 项全部为「无」）")
            return
        # 只把类型报错吃掉，其余照常抛出——静默吞错会让人以为设成功了
        flipped = False
        for e in errors_of(r):
            if e.get("code") != "ENTITY_ERROR.ATTRIBUTE.TYPE":
                continue
            m = re.search(r"/data/attributes/([A-Za-z]+)", e.get("source", {}).get("pointer", ""))
            if m and "BOOLEAN" in e.get("detail", ""):
                attrs[m.group(1)] = False
                flipped = True
        if not flipped:
            die_on_error(r, "设置年龄分级")
    sys.exit("年龄分级：类型协商三轮仍未通过，去网页填")


def cmd_contentrights(tok, app_id):
    body = {"data": {"type": "apps", "id": app_id,
                     "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}
    die_on_error(call(tok, "PATCH", f"/apps/{app_id}", body), "设置内容版权声明")
    print("内容版权声明已设为「不含第三方内容」")


def cmd_price(tok, app_id):
    """免费。价格表要挑一个 CUSTOMER_PRICE 为 0 的价位点。"""
    r = call(tok, "GET", f"/apps/{app_id}/appPricePoints?filter[territory]=USA&limit=200")
    die_on_error(r, "读取价位点")
    free = [p for p in r.get("data", [])
            if str(p["attributes"].get("customerPrice")) in ("0", "0.0", "0.00")]
    if not free:
        sys.exit("没找到 0 元价位点——去网页设免费")
    body = {"data": {"type": "appPriceSchedules",
                     "relationships": {
                         "app": {"data": {"type": "apps", "id": app_id}},
                         "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
                         "manualPrices": {"data": [{"type": "appPrices", "id": "${price1}"}]}}},
            "included": [{"type": "appPrices", "id": "${price1}",
                          "attributes": {"startDate": None},
                          "relationships": {"appPricePoint": {
                              "data": {"type": "appPricePoints", "id": free[0]["id"]}}}}]}
    die_on_error(call(tok, "POST", "/appPriceSchedules", body), "设置免费定价")
    print("价格已设为免费")


# fastlane 的 deliver 本来该管文案，但 2.235.0 上 spaceship 解析回包会抛
# "No data"（上游已知问题），而升 fastlane 会连带动到现役的 beta lane。
# 文案这几个字段就是几条 PATCH，自己打反而稳，构建与上传仍旧交给 fastlane。
#
# 分两处存放，别搞混：随版本走的（描述、关键词、更新说明）在
# appStoreVersionLocalizations，跨版本的（名称、副标题、隐私政策）在
# appInfoLocalizations。
VERSION_FIELDS = {
    "description.txt": "description",
    "keywords.txt": "keywords",
    "marketing_url.txt": "marketingUrl",
    "promotional_text.txt": "promotionalText",
    "support_url.txt": "supportUrl",
    "release_notes.txt": "whatsNew",
}
INFO_FIELDS = {
    "name.txt": "name",
    "subtitle.txt": "subtitle",
    "privacy_url.txt": "privacyPolicyUrl",
}


def read_locale_dir():
    """metadata/ 下每个语言目录读成 {locale: {文件名: 内容}}。"""
    root = os.path.join("fastlane", "metadata")
    if not os.path.isdir(root):
        sys.exit(f"找不到 {root}——在仓库根目录跑")
    out = {}
    for locale in sorted(os.listdir(root)):
        d = os.path.join(root, locale)
        if not os.path.isdir(d) or locale == "review_information":
            continue
        out[locale] = {fn: open(os.path.join(d, fn)).read().strip()
                       for fn in os.listdir(d) if fn.endswith(".txt")}
    return out


def upsert(tok, kind, parent_path, parent_rel, parent_id, locale, attrs, strict=True):
    """按 locale 找现有本地化记录，有就 PATCH，没有就 POST。

    strict=False 时把失败的回包原样交给调用方处理，不当场退出——给需要看
    错误内容再决定怎么办的调用点用。
    """
    existing = call(tok, "GET", f"{parent_path}/{parent_id}/{kind}?limit=50")
    die_on_error(existing, f"读取 {kind}")
    match = next((x for x in existing["data"] if x["attributes"]["locale"] == locale), None)
    if match:
        body = {"data": {"type": kind, "id": match["id"], "attributes": attrs}}
        resp = call(tok, "PATCH", f"/{kind}/{match['id']}", body)
    else:
        body = {"data": {"type": kind, "attributes": dict(attrs, locale=locale),
                         "relationships": {parent_rel: {"data": {"type": parent_path.strip("/"),
                                                                 "id": parent_id}}}}}
        resp = call(tok, "POST", f"/{kind}", body)
    return die_on_error(resp, f"写入 {kind} {locale}") if strict else resp


def cmd_text(tok, app_id):
    v = version(tok, app_id)
    info_id = app_info_id(tok, app_id)
    for locale, files in read_locale_dir().items():
        vattrs = {api: files[fn] for fn, api in VERSION_FIELDS.items() if fn in files}
        iattrs = {api: files[fn] for fn, api in INFO_FIELDS.items() if fn in files}
        if vattrs:
            # 首个版本没有「更新说明」这一栏（没有上一版可对照），带上 whatsNew
            # 会被 409 STATE_ERROR 挡下。这里不预判是不是首版——问 ASC 更准，
            # 被挡下就把这一项摘掉重来，release_notes.txt 留着给 1.0.1 用。
            resp = upsert(tok, "appStoreVersionLocalizations", "/appStoreVersions",
                          "appStoreVersion", v["id"], locale, vattrs, strict=False)
            if any("whatsNew" in e.get("detail", "") for e in errors_of(resp)):
                vattrs.pop("whatsNew", None)
                print(f"{locale}: 首个版本没有更新说明这一栏，已跳过 whatsNew")
                upsert(tok, "appStoreVersionLocalizations", "/appStoreVersions",
                       "appStoreVersion", v["id"], locale, vattrs)
        if iattrs:
            upsert(tok, "appInfoLocalizations", "/appInfos", "appInfo", info_id, locale, iattrs)
        print(f"{locale}: 版本文案 {len(vattrs)} 项、应用信息 {len(iattrs)} 项已写入")


def marketing_version():
    """版本号只有一个来源：ios/project.yml。Fastfile 里也是读的同一处。"""
    spec = open(os.path.join("ios", "project.yml")).read()
    m = re.search(r'^\s*MARKETING_VERSION:\s*"([^"]+)"', spec, re.M)
    if not m:
        sys.exit("ios/project.yml 里读不到 MARKETING_VERSION")
    return m.group(1)


def cmd_setversion(tok, app_id, auto_release=False):
    """版本号对齐 project.yml，并设定发布方式。

    ASC 建版本记录时默认 releaseType=AFTER_APPROVAL（过审即自动上架）。
    要几个端凑同一天放出去就得用 MANUAL，过审后由人点发布；不在乎先后、
    过审即上架就用 auto。
    """
    want = marketing_version()
    v = version(tok, app_id)
    target = "AFTER_APPROVAL" if auto_release else "MANUAL"
    cp = os.path.join("fastlane", "metadata", "copyright.txt")
    want_cp = open(cp).read().strip() if os.path.exists(cp) else None

    editable = {"PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED",
                "METADATA_REJECTED", "INVALID_BINARY"}
    if v is None or v["attributes"]["appStoreState"] not in editable:
        attrs = {"platform": "IOS", "versionString": want, "releaseType": target}
        if want_cp:
            attrs["copyright"] = want_cp
        body = {"data": {"type": "appStoreVersions", "attributes": attrs,
                         "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}}
        die_on_error(call(tok, "POST", "/appStoreVersions", body), "创建新版本记录")
        print(f"已创建新版本 {want}（发布方式: {target}）")
        return

    attrs = {}
    if v["attributes"]["versionString"] != want:
        attrs["versionString"] = want
    if v["attributes"].get("releaseType") != target:
        attrs["releaseType"] = target
    if want_cp and v["attributes"].get("copyright") != want_cp:
        attrs["copyright"] = want_cp
    if not attrs:
        print(f"版本 {want}、{target}，已经是这样")
        return
    body = {"data": {"type": "appStoreVersions", "id": v["id"], "attributes": attrs}}
    die_on_error(call(tok, "PATCH", f"/appStoreVersions/{v['id']}", body), "更新版本记录")
    print(f"版本记录已更新：{', '.join(f'{k}={x}' for k, x in attrs.items())}")


def cmd_attach(tok, app_id, build_number):
    """把构建挂到版本上。

    构建要处理完（processingState=VALID）才挂得上；刚传完通常要等几分钟，
    这期间 ASC 上是 PROCESSING，挂上去会被拒。
    """
    r = call(tok, "GET", f"/apps/{app_id}/builds?limit=200")
    die_on_error(r, "读取构建列表")
    match = [b for b in r["data"] if b["attributes"]["version"] == str(build_number)]
    if not match:
        have = ", ".join(sorted({b["attributes"]["version"] for b in r["data"]}, key=len)[-8:])
        sys.exit(f"没找到构建 {build_number}（现有：{have}）")
    b = match[0]
    state = b["attributes"]["processingState"]
    if state != "VALID":
        sys.exit(f"构建 {build_number} 还在 {state}，等它变 VALID 再挂")
    v = version(tok, app_id)
    body = {"data": {"type": "builds", "id": b["id"]}}
    die_on_error(call(tok, "PATCH", f"/appStoreVersions/{v['id']}/relationships/build", body),
                 "挂载构建")
    print(f"构建 {build_number} 已挂到版本 {v['attributes']['versionString']}")


def cmd_submit(tok, app_id, confirmed):
    """提交审核。

    这是本脚本里唯一一个对外的动作：过审即上架（除非版本设了手动发布），
    撤回要重新排队。所以默认只做体检并把要提交的东西打印出来，加 --yes
    才真的建提交单。
    """
    v = version(tok, app_id)
    if not confirmed:
        print(f"将提交版本 {v['attributes']['versionString']} 进入 Apple 审核。")
        print("先跑 status 确认必填项齐了，确认后加 --yes 重跑。")
        return
    r = call(tok, "POST", "/reviewSubmissions",
             {"data": {"type": "reviewSubmissions", "attributes": {"platform": "IOS"},
                       "relationships": {"app": {"data": {"type": "apps", "id": app_id}}}}})
    # 已经有一份未提交的草稿单就复用，别攒出一堆空提交单
    if "ERROR" in r:
        existing = call(tok, "GET", f"/apps/{app_id}/reviewSubmissions?filter[state]=READY_FOR_REVIEW&limit=1")
        if "ERROR" in existing or not existing.get("data"):
            die_on_error(r, "创建提交单")
        sub_id = existing["data"][0]["id"]
    else:
        sub_id = r["data"]["id"]

    die_on_error(call(tok, "POST", "/reviewSubmissionItems",
                      {"data": {"type": "reviewSubmissionItems",
                                "relationships": {
                                    "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sub_id}},
                                    "appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}}}}),
                 "把版本加进提交单")
    die_on_error(call(tok, "PATCH", f"/reviewSubmissions/{sub_id}",
                      {"data": {"type": "reviewSubmissions", "id": sub_id,
                                "attributes": {"submitted": True}}}),
                 "提交审核")
    print(f"已提交审核：{v['attributes']['versionString']}")


def cmd_category(tok, app_id):
    """主/次类目。是提审必填项，且**建 App 时不会自动带**，新建的 App 一律空着。

    类目是 appInfo 上的关系，不是本地化字段，所以不在 text 那条路里。
    """
    info_id = app_info_id(tok, app_id)
    root = os.path.join("fastlane", "metadata")
    # 走 appInfo 本体的 PATCH。/relationships/primaryCategory 那条子路径是只读的
    # （403 FORBIDDEN_ERROR，只给 GET），别照别的关系的写法套。
    rels = {}
    for fn, rel in (("primary_category.txt", "primaryCategory"),
                    ("secondary_category.txt", "secondaryCategory")):
        path = os.path.join(root, fn)
        if os.path.exists(path):
            rels[rel] = {"data": {"type": "appCategories", "id": open(path).read().strip()}}
    if not rels:
        print("没有 *_category.txt，跳过")
        return
    body = {"data": {"type": "appInfos", "id": info_id, "relationships": rels}}
    die_on_error(call(tok, "PATCH", f"/appInfos/{info_id}", body), "设置类目")
    print(", ".join(f"{k} = {v['data']['id']}" for k, v in rels.items()))


# deliver 的 review_information 目录约定。这些文件是个人信息与凭据，
# 仓库里只留 .example，实文件 gitignore。
REVIEW_FIELDS = {
    "first_name.txt": "contactFirstName",
    "last_name.txt": "contactLastName",
    "phone_number.txt": "contactPhone",
    "email_address.txt": "contactEmail",
    "demo_user.txt": "demoAccountName",
    "demo_password.txt": "demoAccountPassword",
    "notes.txt": "notes",
}


def cmd_review(tok, app_id):
    d = os.path.join("fastlane", "metadata", "review_information")
    if not os.path.isdir(d):
        sys.exit(f"找不到 {d}")
    attrs = {}
    for fn, api in REVIEW_FIELDS.items():
        path = os.path.join(d, fn)
        if os.path.exists(path):
            v = open(path).read().strip()
            if v:
                attrs[api] = v
    missing = [fn for fn in REVIEW_FIELDS if not os.path.exists(os.path.join(d, fn))]
    # 有演示账号就得把 demoAccountRequired 打开，否则 ASC 里那两栏是灰的、填了也不显示
    attrs["demoAccountRequired"] = bool(attrs.get("demoAccountName"))

    v = version(tok, app_id)
    existing = call(tok, "GET", f"/appStoreVersions/{v['id']}/appStoreReviewDetail")
    node = existing.get("data") if "ERROR" not in existing else None
    if node:
        body = {"data": {"type": "appStoreReviewDetails", "id": node["id"], "attributes": attrs}}
        die_on_error(call(tok, "PATCH", f"/appStoreReviewDetails/{node['id']}", body), "更新审核信息")
    else:
        body = {"data": {"type": "appStoreReviewDetails", "attributes": attrs,
                         "relationships": {"appStoreVersion": {
                             "data": {"type": "appStoreVersions", "id": v["id"]}}}}}
        die_on_error(call(tok, "POST", "/appStoreReviewDetails", body), "创建审核信息")
    print(f"审核信息已写入：{', '.join(sorted(attrs))}")
    if missing:
        print(f"缺（ASC 提审时是必填）：{', '.join(sorted(missing))}")


# 6.9 吋（iPhone 17/16 Pro Max，1320x2868）在 ASC 里的枚举名仍是 IPHONE_67。
SCREENSHOT_DISPLAY_TYPE = "APP_IPHONE_67"


def cmd_screenshots(tok, app_id, root=None, display_type=SCREENSHOT_DISPLAY_TYPE):
    """把 fastlane/screenshots/<locale>/ 下的图传到对应语言的截图组。

    ASC 传文件是三段式：先 POST 预留一条记录拿 uploadOperations，再按它给的
    分片把字节 PUT 上去，最后 PATCH uploaded=true 并附 md5。少最后一步的话
    记录会一直挂在「上传中」，网页上看得见但提审用不了。
    """
    import hashlib
    root = root or os.path.join("fastlane", "screenshots")
    if not os.path.isdir(root):
        sys.exit(f"找不到 {root}")
    v = version(tok, app_id)
    locs = call(tok, "GET", f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations?limit=20")
    die_on_error(locs, "读取版本本地化")

    for loc in locs["data"]:
        locale = loc["attributes"]["locale"]
        d = os.path.join(root, locale)
        if not os.path.isdir(d):
            print(f"{locale}: 没有对应目录，跳过")
            continue
        files = sorted(f for f in os.listdir(d) if f.lower().endswith((".png", ".jpg", ".jpeg")))
        if not files:
            print(f"{locale}: 目录是空的，跳过")
            continue

        sets = call(tok, "GET", f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets?limit=20")
        die_on_error(sets, "读取截图组")
        node = next((x for x in sets["data"]
                     if x["attributes"]["screenshotDisplayType"] == display_type), None)
        if node:
            set_id = node["id"]
            # 重传前清空，否则会在已有图后面追加，顺序和数量都不受控
            existing = call(tok, "GET", f"/appScreenshotSets/{set_id}/appScreenshots?limit=20")
            for old in existing.get("data", []):
                call(tok, "DELETE", f"/appScreenshots/{old['id']}")
        else:
            r = call(tok, "POST", "/appScreenshotSets",
                     {"data": {"type": "appScreenshotSets",
                               "attributes": {"screenshotDisplayType": display_type},
                               "relationships": {"appStoreVersionLocalization": {"data": {
                                   "type": "appStoreVersionLocalizations", "id": loc["id"]}}}}})
            die_on_error(r, "创建截图组")
            set_id = r["data"]["id"]

        for fn in files:
            path = os.path.join(d, fn)
            blob = open(path, "rb").read()
            r = call(tok, "POST", "/appScreenshots",
                     {"data": {"type": "appScreenshots",
                               "attributes": {"fileSize": len(blob), "fileName": fn},
                               "relationships": {"appScreenshotSet": {"data": {
                                   "type": "appScreenshotSets", "id": set_id}}}}})
            die_on_error(r, f"预留 {fn}")
            shot_id = r["data"]["id"]
            for op in r["data"]["attributes"]["uploadOperations"]:
                chunk = blob[op["offset"]:op["offset"] + op["length"]]
                req = urllib.request.Request(op["url"], method=op["method"], data=chunk)
                for h in op["requestHeaders"]:
                    req.add_header(h["name"], h["value"])
                urllib.request.urlopen(req)
            die_on_error(call(tok, "PATCH", f"/appScreenshots/{shot_id}",
                              {"data": {"type": "appScreenshots", "id": shot_id,
                                        "attributes": {"uploaded": True,
                                                       "sourceFileChecksum": hashlib.md5(blob).hexdigest()}}}),
                         f"确认 {fn}")
            print(f"  {locale}  {fn}  已上传")


def cmd_availability(tok, app_id):
    """上架区域：全球所有区。

    2026-09-05 起北京主体这条 App 记录就是全球版：另一条 App 记录被 4.3(a) 判定
    与它重复，iOS 整体并入北京主体，那条记录已删（dev-board#445/#446）。

    已有 appAvailabilities 记录的 App（上架过的都有）再 POST v2/appAvailabilities 会 409
    「already exists」，只能逐区 PATCH v1/territoryAvailabilities/{id}；从未设过的才 POST，
    且 POST 必须把所有区列全，少一个就 409 说那个区没被 included。
    """
    def want(_territory):
        return True
    label = "全球"

    existing = call(tok, "GET", BASE_V2 + f"/appAvailabilities/{app_id}/territoryAvailabilities?limit=200")
    if "ERROR" not in existing:
        rows = existing["data"]
        changed, failed = 0, []
        for row in rows:
            tid = row["id"]
            # id 是 base64 的 {"s": app, "t": 区域码}
            territory = json.loads(base64.b64decode(tid + "=" * (-len(tid) % 4)))["t"]
            target = want(territory)
            if row["attributes"]["available"] == target:
                continue
            r = call(tok, "PATCH", f"/territoryAvailabilities/{tid}",
                     {"data": {"type": "territoryAvailabilities", "id": tid,
                               "attributes": {"available": target}}})
            if "ERROR" in r:
                failed.append((territory, errors_of(r)))
            else:
                changed += 1
        # availableInNewTerritories 对已有记录只能网页改（API 对 appAvailabilities
        # 只开放 CREATE / GET，PATCH 直接 403），这里不动。
        for territory, errs in failed:
            print(f"  ! {territory}: {errs}")
        if failed:
            sys.exit(f"上架区域：改了 {changed} 个区，{len(failed)} 个区失败")
        print(f"上架区域已设置（{label}）：本次改了 {changed} 个区，共 {len(rows)} 个区")
        return

    r = call(tok, "GET", "/territories?limit=200")
    die_on_error(r, "读取区域列表")
    territories = [t["id"] for t in r["data"]]
    if "CHN" not in territories:
        sys.exit("区域列表里没有 CHN，别往下走")

    refs, included = [], []
    for t in territories:
        key = f"t-{t}"
        refs.append({"type": "territoryAvailabilities", "id": "${" + key + "}"})
        included.append({
            "type": "territoryAvailabilities", "id": "${" + key + "}",
            "attributes": {"available": want(t)},
            "relationships": {"territory": {"data": {"type": "territories", "id": t}}}})

    body = {"data": {"type": "appAvailabilities",
                     "attributes": {"availableInNewTerritories": True},
                     "relationships": {
                         "app": {"data": {"type": "apps", "id": app_id}},
                         "territoryAvailabilities": {"data": refs}}},
            "included": included}
    resp = call(tok, "POST", BASE_V2 + "/appAvailabilities", body)
    die_on_error(resp, "设置上架区域")
    on = sum(1 for i in included if i["attributes"]["available"])
    print(f"上架区域已设置：{on}/{len(territories)} 个区可用（{label}）")


def cmd_status(tok, app_id):
    """提审前必填项体检。只读，不改任何东西。"""
    app = call(tok, "GET", f"/apps/{app_id}")
    die_on_error(app, "读取 app")
    a = app["data"]["attributes"]
    v = version(tok, app_id)
    info = call(tok, "GET", f"/apps/{app_id}/appInfos")
    ia = info["data"][0]["attributes"]
    rating = call(tok, "GET", f"/appInfos/{info['data'][0]['id']}/ageRatingDeclaration")
    ra = rating.get("data", {}).get("attributes", {})

    print(f"== {a['name']} / {a['bundleId']} ==")
    print(f"版本            {v['attributes']['versionString']}  {v['attributes']['appStoreState']}"
          f"  发布方式 {v['attributes'].get('releaseType')}")
    print(f"内容版权声明    {a.get('contentRightsDeclaration') or '未填'}")
    print(f"年龄分级        {ia.get('appStoreAgeRating') or '未填'}")
    cats = []
    for rel in ("primaryCategory", "secondaryCategory"):
        c = call(tok, "GET", f"/appInfos/{info['data'][0]['id']}/{rel}")
        cats.append((c.get("data") or {}).get("id", "未设") if "ERROR" not in c else "未设")
    print(f"类目            主 {cats[0]} / 次 {cats[1]}")
    # 只看问卷本身：ageRatingOverride 这类字段建记录时就有值，拿它判断会永远显示「已答」
    answered = sum(1 for f in RATING_FIELDS if ra.get(f) is not None)
    print(f"分级问卷        {answered}/{len(RATING_FIELDS)} 项已答")

    locs = call(tok, "GET", f"/appStoreVersions/{v['id']}/appStoreVersionLocalizations?limit=20")
    have = [l["attributes"]["locale"] for l in locs.get("data", [])]
    print(f"版本文案语言    {', '.join(have) if have else '无'}")
    for loc in locs.get("data", []):
        la = loc["attributes"]
        shots = call(tok, "GET",
                     f"/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets?limit=20")
        n = len(shots.get("data", []))
        print(f"  {la['locale']:<8} 描述{'有' if la.get('description') else '缺'} "
              f"关键词{'有' if la.get('keywords') else '缺'} "
              f"支持URL{'有' if la.get('supportUrl') else '缺'} 截图组 {n}")

    build = call(tok, "GET", f"/appStoreVersions/{v['id']}/build")
    b = build.get("data") if "ERROR" not in build else None
    print(f"已挂构建        {b['id'] if b else '未挂'}")
    review = call(tok, "GET", f"/appStoreVersions/{v['id']}/appStoreReviewDetail")
    rdata = review.get("data") if "ERROR" not in review else None
    rd = rdata.get("attributes") if rdata else None
    print(f"审核联系信息    {'已填' if rd and rd.get('contactEmail') else '未填'}")
    print(f"演示账号        {'已填' if rd and rd.get('demoAccountName') else '未填'}")
    print("ICP 备案号      API 不开放，去网页「App 信息」核对（京ICP备2024096997号-13A）")
    print("隐私营养标签    API 未在本脚本覆盖，去网页「App 隐私」核对")


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]
    tok = token_for()
    app_id = APP_ID
    if cmd == "setversion":
        cmd_setversion(tok, app_id, auto_release="auto" in sys.argv)
    elif cmd == "attach":
        if len(sys.argv) < 3:
            sys.exit("用法：asc-listing.py attach <构建号>")
        cmd_attach(tok, app_id, sys.argv[2])
    elif cmd == "submit":
        cmd_submit(tok, app_id, "--yes" in sys.argv)
    elif cmd == "screenshots":
        cmd_screenshots(tok, app_id)
    elif cmd == "watch-screenshots":
        if len(sys.argv) != 3:
            sys.exit("用法：asc-listing.py watch-screenshots <包含 zh-Hans/en-US 的截图目录>")
        cmd_screenshots(tok, app_id, root=sys.argv[2], display_type="APP_WATCH_SERIES_10")
    elif cmd == "review":
        cmd_review(tok, app_id)
    elif cmd == "category":
        cmd_category(tok, app_id)
    elif cmd == "text":
        cmd_text(tok, app_id)
    elif cmd == "rating":
        cmd_rating(tok, app_id)
    elif cmd == "contentrights":
        cmd_contentrights(tok, app_id)
    elif cmd == "price":
        cmd_price(tok, app_id)
    elif cmd == "availability":
        cmd_availability(tok, app_id)
    elif cmd == "status":
        cmd_status(tok, app_id)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
