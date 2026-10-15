# Mobile password sign-in

Development board: zeweihan/dev-board#1299. Four maintained clients: iOS SwiftUI, Android Compose, Harmony ArkTS, WeChat mini program.

## Account authority and flow

The regional website is the only password authority. Normal sign-in is `POST /api/auth/account-login {account,password}` to the existing regional Java backend. Java validates against the website and retains the existing Java user identity; the mobile client must not create a user, re-key project paths, or store a second password. Passwords are sent unchanged, including whitespace, and never persisted by the client.

The bridge preserves `token/userId/...` for desktop and additionally returns the mobile-compatible `sessionId/user` in the ordinary `{code,message,data}` envelope. `sessionId` contains the device token; existing `X-Session-Id` request headers and session stores remain in use. A setup challenge is not a complete mobile login and must never be saved as a session. A successful login requires a nonempty session and a positive user ID.

First use / set password and forgot password open these fixed regional URLs:

- China: `https://aiworkdeck.com/zh/account?flow=register` or `flow=reset`.
- Global: `https://workdeck.ai/en/account?flow=register` or `flow=reset`.

The website owns the captcha, first verification, mandatory password setup, and reset state machine. It informs users to return to the app after saving the password. iOS/Android/Harmony use the system browser. No credentials or account identifiers are included in the URL. Returning users sign in with the newly saved password. Entering either website flow clears the in-memory password and returns the app to ordinary password mode.

The explicit App review secondary entry is the only client entry to legacy phone/email verification. It does not request a code and never activates automatically based on credential length or a failed password login. The Java review gate must reject every identity except its existing exact review account allowlist. This entry is for the existing store review instructions; it is not a second normal sign-in method.

The mini program's international account capability remains disabled. Its new account page uses a fixed China website `web-view` URL, and the old WeChat referral start page enters this same registration flow. It no longer requests a WeChat ticket/session directly. Public referral tags matching `u-<username>` are retained through the registration URL; all other values are dropped. A failed web-view shows the fixed website URL and a copy button for opening it in the browser; this fallback does not replace business-domain acceptance.

## Validation and release gates

Local checks on 2026-10-15: Node typecheck, full Node tests, contract generation/check, palette check, Swift syntax parsing, and whitespace diff check. Synthetic API tests prove exact password transmission, identity/session persistence, challenge rejection, and no login persistence on malformed/rejected responses. Mini program page tests cover navigation, password clearing, region switching while busy, and explicit review mode.

Local machine has Command Line Tools but no Xcode, Java runtime, Android SDK, or DevEco Studio. Swift parsing is not type checking, native compilation, or UI execution. Do not report native build or visual acceptance from these local checks.

- Android: existing `.github/workflows/android.yml` builds both `cn` and `intl` debug variants and runs `testIntlDebugUnitTest` on a PR.
- iOS: `.github/workflows/ios-auth-check.yml` is a non-publishing simulator build/test workflow. It runs WorkdeckTests plus LoginFlowTests and the existing landscape login test, and uploads xcresult, including the UI screenshot. It never uploads an App Store build.
- Harmony: run `harmony/README.md`'s DevEco/hvigor build on a host with the configured SDK; Node domain tests do not compile ArkUI.
- Mini program: typecheck/page tests do not prove WeChat `web-view` availability. The repository and service inventory contain no verified business-domain configuration for `aiworkdeck.com`. Before release, verify that domain and any website redirect domains in the WeChat console and exercise register/reset in a real trial build; if unavailable, the account flow remains a release gap. This is distinct from request/upload domain registration.

Required end-to-end acceptance: fresh phone/email verification -> mandatory password creation -> return and password login; repeat password login sends no code; password reset invalidates the old password; existing mobile user's user ID and project catalog remain unchanged; wrong password and ordinary OTP/review attempts create no session. Use an isolated synthetic test account, never the user's account or review account for developer testing. Native link clicks and the first actual website screen must be checked in the shipped client.
