# Mini-program dependency security review (2026-11-16)

Scope: dev-board #1753 (dependencies) and #1754 (workflow permissions). This change does not upload an application, sign a build, change production credentials, or deploy.

## Fixes and compatibility

- Pin `miniprogram-ci` to 2.1.48 and `miniprogram-automator` to 0.13.0. The registry's `latest` tag still reported 2.1.31; the newer published SDK removes Babel 6 and the `download`/`decompress` chain. Do not infer available patches from `latest` alone.
- Refresh compatible transitive versions and explicitly override stale upstream pins. Replace deprecated `request` with the maintained Cypress `@cypress/request` 4.0.1 fork; [the original cross-protocol redirect advisory](https://github.com/advisories/GHSA-p8p7-x288-28g6) is fixed by the fork since 3.0.0. Upgrade `gulp-plumber` to its compatible 1.2.1 release, removing `gulp-util` and `lodash.template`.
- Use maintained `file-type` 22.3.0 and `image-size` 2.1.0 parsers. `prepare` verifies exact original file SHA-256 values before adapting four SDK call sites: Jimp's asynchronous `fromBuffer` to `fileTypeFromBuffer`, the native iOS compiler's synchronous path/Buffer image-size calls to the named `imageSize` parser with explicit file reading, and both Jimp versions' callback requests to `phin.unpromisified`. No parser implementation is copied. Preparation is idempotent and rejects changed caller source. A failed preparation is a failed installation.
- Scope the `image-size` override to the SDK; Less's separate image-size 0.5.4 API remains unchanged. The older automator's file-type 9 API also remains unchanged and is outside the identified affected ranges.
- Local `file:` override adapters were tested and discarded: npm 10 resolves these relative to transitive consumers and can produce broken links even when installation succeeds. No such override or local adapter remains.
- Both flagged workflows now declare only `contents: read`. The contract workflow also runs the full dependency security gate, including development dependencies.

## Remaining exact exceptions

These are reachability exceptions, not patched packages or a claim that npm audit returns zero. The html-minifier finding was already present in the baseline npm audit, although it was not one of the original 68 open GitHub alerts. Raw final audit reports three package records (one moderate and two high), representing the following two advisories and the SDK's inherited record. All other advisories fail `npm run security:dependencies`. Exceptions expire on **2027-02-14 UTC**, or earlier if the reviewed SDK, node location, exact exception versions, dependency consumers, source fingerprints, or dependency scope changes.

1. Follow-up dev-board #1758: `html-minifier` 4.0.0, [GHSA-pfq8-rq6v-vf5m](https://github.com/advisories/GHSA-pfq8-rq6v-vf5m): an obsolete direct dependency of SDK 2.1.48. Review found no reference in the SDK's executable JavaScript or native assets; the offline compilation probe does not load it. The gate scans those files again and rejects a newly introduced reference. The package itself has no upstream patch; the maintained html-minifier-terser's current API is asynchronous, so it cannot be blindly substituted for the old synchronous interface. Introducing a caller requires removing this exception and revisiting the replacement.
2. Follow-up dev-board #1759: `uuid` 3.4.0, [GHSA-w5hq-g745-h8pq](https://github.com/advisories/GHSA-w5hq-g745-h8pq), original alert #42: the advisory applies to `v3`/`v5`/`v6` with caller-supplied output buffers. The only installed consumer is SDK `nativecompiler/ios/buildCloud.js`, which imports `uuid/v4` and calls it with no arguments. The SDK's exact caller fingerprint and unique v4 import are checked by the gate. A blind upgrade to uuid 11 removes the `uuid/v4` deep import and breaks SDK initialization. This exception does not authorize use of v3/v5/v6.

## Verification

`npm ci` executes the compatibility patch; `npm run typecheck`, `npm test`, `node contract/tools/check.mjs`, `node scripts/check-palette.mjs`, and `npm run security:dependencies` cover the normal checks. The added bounded subprocess probe uses the real SDK JavaScript compiler, both actual Jimp versions (buffer and real loopback URL reads), valid PNG round trips, actual Less image-width/image-height compilation, the installed native SDK size expression with both a PNG path and a Buffer, malformed ASF and ICNS headers, actual SDK protobuf conversion, both COS SDKs’ configured XML wrapper APIs (including string-valued identifiers), temporary-file APIs, and real loopback HTTP requests including cross-protocol redirect rejection. No upload or developer-tools connection occurs. The native iOS probe extracts and executes the exact installed SDK size expression; it does not run a native cloud build. The active uploader uses cos-nodejs-sdk-v5 3.0.0 with its vendor-maintained cos-fast-xml-parser. cos-js-sdk-v5 1.8.6 is an unreferenced SDK dependency with a prebundled parser: the fast-xml-parser override updates its source dependency, not the embedded bundle. No claim is made that the bundle has been rewritten; the SDK's executable sources contain no cos-js-sdk-v5 import. The source XML wrapper is tested to verify compatibility with the override.

The dependency gate has negative tests for new advisories, expiry, production scope, unexpected locations, changed versions, added consumers and malformed reports. Patch idempotence and changed-source rejection are also verified. Runtime mobile UIs, native miniapp iOS cloud compilation, actual WeChat upload, signed Android/iOS builds and store distribution are outside this dependency-only validation and were not performed.

## Original Dependabot alert disposition

The original 68 open alerts were captured before edits. This table compares each advisory's original affected range with every matching node in the final lock. “Fixed/removed” means the candidate lock no longer includes an affected node; the remote default-branch alert state must be rechecked after merge. PRs 125/126/127 are incorporated by the same-or-newer fast-uri/follow-redirects/postcss-selector-parser nodes and should be closed as superseded only after the combined fix merges.

| Alert | Advisory | Package | Final version(s) | Disposition |
| --- | --- | --- | --- | --- |
| #1 | GHSA-vh95-rmgr-6w4m | minimist | 1.2.8 | Fixed/removed |
| #4 | GHSA-pfrx-2q88-qq97 | got | removed | Fixed/removed |
| #7 | GHSA-9c47-m6qq-7p4h | json5 | 2.2.3 | Fixed/removed |
| #9 | GHSA-xvch-5gv4-984h | minimist | 1.2.8 | Fixed/removed |
| #10 | GHSA-p8p7-x288-28g6 | request | @cypress/request@4.0.1 | Fixed/removed |
| #11 | GHSA-72xf-g2v4-qvf3 | tough-cookie | 5.1.2, 4.1.4 | Fixed/removed |
| #12 | GHSA-67hx-6x53-jw92 | @babel/traverse | 7.29.14, 7.24.6 | Fixed/removed |
| #13 | GHSA-67hx-6x53-jw92 | babel-traverse | removed | Fixed/removed |
| #14 | GHSA-x565-32qp-m3vf | phin | 3.7.1 | Fixed/removed |
| #15 | GHSA-35jh-r3h4-6jhm | lodash.template | removed | Fixed/removed |
| #19 | GHSA-fjxv-7rqg-78g4 | form-data | 2.5.6, 4.0.6 | Fixed/removed |
| #20 | GHSA-52f5-9888-hmc6 | tmp | 0.2.7 | Fixed/removed |
| #21 | GHSA-6rw7-vpxm-498p | qs | 6.17.1 | Fixed/removed |
| #25 | GHSA-7r86-cg39-jmmj | minimatch | 3.1.5 | Fixed/removed |
| #26 | GHSA-jmr7-xgp7-cmfj | fast-xml-parser | 5.12.0 | Fixed/removed |
| #28 | GHSA-fj3w-jwp8-x2g3 | fast-xml-parser | 5.12.0 | Fixed/removed |
| #30 | GHSA-8gc5-j5rx-235r | fast-xml-parser | 5.12.0 | Fixed/removed |
| #31 | GHSA-jp2q-39xq-3w4g | fast-xml-parser | 5.12.0 | Fixed/removed |
| #32 | GHSA-gh4j-gqv2-49f6 | fast-xml-parser | 5.12.0 | Fixed/removed |
| #33 | GHSA-fv7c-fp4j-7gwp | @babel/plugin-transform-modules-systemjs | 7.29.4 | Fixed/removed |
| #34 | GHSA-q6x5-8v7m-xcrf | protobufjs | 7.6.6 | Fixed/removed |
| #36 | GHSA-jvwf-75h9-cwgg | protobufjs | 7.6.6 | Fixed/removed |
| #37 | GHSA-75px-5xx7-5xc7 | protobufjs | 7.6.6 | Fixed/removed |
| #38 | GHSA-fx83-v9x8-x52w | protobufjs | 7.6.6 | Fixed/removed |
| #39 | GHSA-66ff-xgx4-vchm | protobufjs | 7.6.6 | Fixed/removed |
| #40 | GHSA-2pr8-phx7-x9h3 | protobufjs | 7.6.6 | Fixed/removed |
| #42 | GHSA-w5hq-g745-h8pq | uuid | 3.4.0 | v4-only exception above |
| #43 | GHSA-ph9p-34f9-6g65 | tmp | 0.2.7 | Fixed/removed |
| #44 | GHSA-4x5r-pxfx-6jf8 | @babel/core | 7.29.6 | Fixed/removed |
| #45 | GHSA-hmw2-7cc7-3qxx | form-data | 2.5.6, 4.0.6 | Fixed/removed |
| #48 | GHSA-mp2f-45pm-3cg9 | decompress | removed | Fixed/removed |
| #49 | GHSA-xcpc-8h2w-3j85 | adm-zip | 0.6.1 | Fixed/removed |
| #50 | GHSA-h39j-r5qq-r9mm | decompress | removed | Fixed/removed |
| #51 | GHSA-jwp9-9v96-94mx | decompress | removed | Fixed/removed |
| #52 | GHSA-vcc3-ghjq-m6fr | decode-uri-component | removed | Fixed/removed |
| #54 | GHSA-6gmq-8vp8-gcm6 | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #56 | GHSA-93r5-fhx6-vmg9 | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #58 | GHSA-8344-3jmq-59r6 | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #59 | GHSA-6h8r-xr42-gp59 | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #60 | GHSA-vr34-hp96-76pp | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #61 | GHSA-3px3-54cx-rmw9 | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #62 | GHSA-27p8-2357-5qqv | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #63 | GHSA-jxjr-3g7g-3944 | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #64 | GHSA-c7q8-3ch8-vqpv | @xmldom/xmldom | 0.9.12 | Fixed/removed |
| #65 | GHSA-4vpr-x523-8j87 | svgo | 2.8.4 | Fixed/removed |
| #66 | GHSA-w27v-7q3p-w38r | svgo | 2.8.4 | Fixed/removed |
| #67 | GHSA-vwc7-r8mq-g2x9 | adm-zip | 0.6.1 | Fixed/removed |
| #68 | GHSA-2883-xcg3-v3hh | js-yaml | 4.3.2 | Fixed/removed |
| #69 | GHSA-7q85-xj36-vmfc | adm-zip | 0.6.1 | Fixed/removed |
| #72 | GHSA-58mr-gqgx-xq4g | fast-uri | 3.1.9 | Fixed/removed |
| #73 | GHSA-qw65-cvwx-89v3 | fast-uri | 3.1.9 | Fixed/removed |
| #74 | GHSA-j5f4-cc29-5x44 | adm-zip | 0.6.1 | Fixed/removed |
| #78 | GHSA-p634-w6r4-rjp2 | adm-zip | 0.6.1 | Fixed/removed |
| #83 | GHSA-q2hr-2g5m-vwhr | brace-expansion | 1.1.22 | Fixed/removed |
| #84 | GHSA-q2hr-2g5m-vwhr | brace-expansion | 1.1.22 | Fixed/removed |
| #85 | GHSA-4p3w-j4w9-5jqw | moment | 2.31.0 | Fixed/removed |
| #86 | GHSA-hrh2-vp3x-79xf | decompress | removed | Fixed/removed |
| #88 | GHSA-68fv-2mgg-jv7q | source-map-js | 1.2.2 | Fixed/removed |
| #89 | GHSA-8r9p-f939-6h3c | follow-redirects | 1.16.3 | Fixed/removed |
| #90 | GHSA-q3jh-wrc6-jgq8 | follow-redirects | 1.16.3 | Fixed/removed |
| #91 | GHSA-333x-w4r6-6crp | fast-uri | 3.1.9 | Fixed/removed |
| #92 | GHSA-wjr9-j795-jxcr | fast-uri | 3.1.9 | Fixed/removed |
| #93 | GHSA-xhq7-xmqj-769h | fast-uri | 3.1.9 | Fixed/removed |
| #94 | GHSA-w74x-v6f9-j3xg | fast-uri | 3.1.9 | Fixed/removed |
| #95 | GHSA-rj75-hqrm-r3gf | postcss-selector-parser | 6.1.6, 7.2.1 | Fixed/removed |
| #96 | GHSA-qr28-fpjm-wq7f | decode-uri-component | removed | Fixed/removed |
| #97 | GHSA-mrwp-f3q8-3g9p | follow-redirects | 1.16.3 | Fixed/removed |
| #98 | GHSA-474x-hrwr-fgx4 | fast-xml-parser | 5.12.0 | Fixed/removed |
