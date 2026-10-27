<!-- SPDX-FileCopyrightText: 2026 北京京微资易科技有限公司 and AI WorkDeck contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Mobile personal workspace — dev-board #1539 / #1540

The signed-in root now offers Personal assistant, Calendar, Projects and Capture. Asking a question never requires choosing a project. Opening an answer source or a calendar attachment uses a separate preview target, so it does not change the current capture archive destination. Existing recording services continue independently of personal pages; video/camera operations retain their existing navigation guards.

## Consent and account boundary

All requests use the frozen account's `X-Session-Id` and the current account-region host. Assistant text is submitted only after the service reports `enabled`. Users explicitly consent once to cloud AI processing of summaries from projects with backup enabled. Calendar synchronization has its own explicit consent. Both use `2026-10-27`, generated from the shared contract. Subscription and backup status come from the server. Existing account settings and cloud-backup settings remain reachable; this change adds no mobile subscription purchasing or payment flow. Subscription purchase continues through existing account/website channels, not the credits top-up page.

The latest conversation ID and unresolved question (original request ID, text and conversation ID) are saved in account-scoped local storage before submission. On re-entry the client first queries `GET assistant/requests/{id}`; a completed result is recovered through conversation history, a running result is polled, and a failed/unknown result retains the original input for an explicit retry. Recovery does not automatically POST a failed question. A completed history is read from `GET assistant/conversations/{id}`. There is no new conversation-list UI. Logout, region/account changes and successful revocation clear local personal state; late callbacks cannot write into a different account. Retry idempotency prevents duplicate submissions but does not promise that prior failed model work was unbilled.

## Calendar and reminders

Calendar uses the server's complete account snapshot, filters by stable project identity and the event's timezone, and offers Today / next 3 / next 5 days. Events expose their source project and associated files. A disabled or unsubscribed response cancels existing reminders. A transport failure retains the previous snapshot instead of treating it as an empty calendar.

- iOS schedules the next 50 future OPEN events with `UNUserNotificationCenter`. Closing the app does not remove already scheduled local reminders, but new desktop changes require a fresh calendar sync. Notification taps select the matching event. Logout removes pending and delivered calendar notifications. Notification content is generic and does not expose the event title or project name on the lock screen.
- Android schedules the next 50 with WorkManager and checks the account scope when work executes. Battery-saving policies can delay delivery; no exact-alarm permission is requested.
- Harmony uses `reminderAgentManager`, requests notification permission, keeps the published reminder IDs, and cancels them when the account or enabled snapshot changes. It requires `PUBLISH_AGENT_REMINDER` and the platform's reminder capability.
- WeChat displays the synchronized calendar and associated projects. Background subscription notifications are unavailable until a suitable approved template and server delivery integration exist. The UI does not claim to have sent push notifications.

## Optional APNs source integration

The default iOS build keeps `AWD_CALENDAR_REMOTE_PUSH=NO`; no production certificate, provisioning profile, Apple account or backend secret was changed. `CalendarPushDelegate` supports token registration and event-ID click routing. Remote device PUT and DELETE operations are serialized for one installation, so a delayed old-account registration cannot overtake logout cleanup. A previously acknowledged channel remains known after transient failures, avoiding a switch to duplicate local reminders. Offline logout clears local data immediately; remote unregistration cannot be guaranteed until the server request succeeds.

To enable a future signed build, the **Workdeck app target only** must use `CalendarPush.entitlements` as its `CODE_SIGN_ENTITLEMENTS`, set `AWD_CALENDAR_REMOTE_PUSH=YES` and choose `AWD_APNS_ENVIRONMENT=sandbox` or `production`, with a matching Push-enabled Beijing-team profile. The server must separately have that team's APNs configuration. This task does not perform those steps. After the server acknowledges registration, local calendar scheduling is suspended. Without server availability the app continues local scheduling. APNs alert `loc-key` is exactly `personal.reminders`; `contract/tools/gen.mjs` generates `ios/Resources/<locale>.lproj/Localizable.strings` for all 20 locales.

## Verification

Synthetic transport tests cover unchanged request UUIDs, running/failed responses, account isolation, timezone filters, reminder ordering and limits, persistence and recovery through GET requests, revocation, and the 20-language APNs resources. iOS UI tests launch an isolated synthetic account with URLProtocol interception; they exercise assistant → answer → calendar → event files → projects → capture without selecting a project first. The fixture is compiled only for Debug and requires explicit UI-test launch arguments. No production account or billable model call is involved.

Platform reminder delivery on locked physical devices, actual APNs credentials and production server delivery remain separate device/integration verification. Android and Harmony compilation and model tests are not a claim of physical-device notification delivery. WeChat has no approved background reminder template in this change. See the task's QA record for exact build commands and observed results.
