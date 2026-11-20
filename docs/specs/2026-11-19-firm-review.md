<!-- SPDX-FileCopyrightText: 2026 北京公富信息技术有限公司 and AI WorkDeck contributors -->
<!-- SPDX-License-Identifier: AGPL-3.0-or-later -->
# Firm review on the phone (iOS first)

A lawyer reviews, answers and signs off client matters that come from a law firm's client-intake portal, from the phone,
in about a minute. The first portal is a firm's AI intake service (drafts by an assistant, red flags settled with the
client, a list "for the lawyer"); the feature is generic and carries no firm name in the app.

## Who sees it (access and business model)

- Invisible to ordinary users. It appears as a **Reviews** tab only after the signed-in AI WorkDeck account joins a firm portal.
- Joining: Settings → *Firm review* → paste the office link the firm sent (for example `…/tw/`). The app resolves it to an
  allowlisted portal (host plus office path) and calls `<portal>/api/portal/me` with the account's session token. A new account shows *Waiting for the firm to approve you*. Once approved, the tab appears.
  A revoked account loses it.
- The firm is the customer: the firm enables lawyers' seats on its portal (sold to firms, outside the app). The lawyer
  never sees a paywall, so no in-app purchase is involved. Approval on the portal *is* the entitlement for v1. A later
  server step can record it as an AI WorkDeck advanced feature, so the account page and other clients know about it.
- A trial code can be typed in for demos. It is never bundled. It is stored in the Keychain (this device only, never
  synced). If the code cannot be stored, joining fails: the app never falls back to sending the account session instead.
- Links and trial codes are scoped to the account (region host + verified user id). A restored session's placeholder
  id 0 is never used as a scope; the app asks `/api/auth/me` first and keeps the tab hidden while offline.
- **Token safety:** the AI WorkDeck session token is sent only to portal hosts listed in `contract/capabilities.json`
  (`firmPortals`: https host plus an optional office path such as `/tw`). An arbitrary link cannot harvest the session. Long term, the backend should issue portal-scoped tokens.

## Screens

1. **Reviews (inbox).** Sections: *Needs you* (review requested, call requested, client replied), *Waiting on client*,
   *In progress*, *Signed and closed*. Each row shows the client/company, the document, and why it needs you, plus a count of items for the lawyer and the time. Pull to refresh.
2. **Matter.** One scroll, partner order:
   1. header: document, client, status, requested lawyer, call request;
   2. **For the lawyer**: the client's list, each with its section and flag;
   3. red flags: how each was settled (changed / kept / for the lawyer);
   4. what changed: the version's change notes plus a paragraph diff against the previous version;
   5. the document: rendered from Markdown, readable on a phone; PDF of any version;
   6. conversation: collapsed, opens on tap.
3. **Bottom bar (one thumb):** *Reply* · *More* (confirm call, mark call done, send back to client, small fix) · **Sign off**.
   - Reply: a text sheet with three starters (question, engagement terms, call time).
   - Small fix: edit the latest version's Markdown and save it as a new version, with a one-line note.
   - Sign off: three confirmations (conflict check, engagement, "I reviewed version N"), the lawyer's name (pre-filled,
     editable), then Face ID / passcode. The server refuses if the version changed (`version_changed`). The app then reloads and says so.
     On success it shows the signed PDF that the client receives.

## Notifications

- **Now (no server change):** while the Reviews tab is on screen it refreshes every 30 s, on pull-to-refresh, and when the app
  returns to the foreground; the tab badge counts what needs the lawyer. This is honest but not instant.
- **Instant (needs the server):** portal → AI WorkDeck backend event webhook (HMAC-signed; matter id, kind and recipient
  account ids only) → the existing APNs gateway → a content-free push with `mutable-content`. A Notification Service
  Extension fetches the matter summary from the portal over HTTPS and writes "Acme Inc. · SAFE · review requested".
  So no client data passes through the push service. The lock screen shows client details only if the lawyer enables that.
- Prerequisite: Push enabled on the Beijing team's App ID and an APNs key on the backend (`mobile.calendar.apns.*`),
  `AWD_CALENDAR_REMOTE_PUSH=YES` in release builds.

## Portal contract (live on the portal side, 2026-11-19)

1. Portals: `/all` (all offices; the site root), `/sv` (Silicon Valley), `/tw` (Taipei), `/jp` (Tokyo), `/sg` (Singapore)
   on `aifirm.aiworkdeck.com`; each serves `<office>/api/portal/*` with its own matters and lawyers. A link resolves by its
   first path segment; the site root resolves to `/all`; other segments (event pages) are refused. Office text is shown as delivered (Taipei: Traditional Chinese).
2. Visibility: a lawyer account sees matters requested for its `lawyerId` plus unassigned ones; anything else is 404.
3. `GET me` → `kind`, `status` (`pending` | `approved` | `revoked`), `firm` `{en, zh}`, `lawyerName` `{en, zh}`, `trialUntil`.
4. List items carry `attention` (`review_requested` | `call_requested` | `client_replied` | null) and `attentionAt`;
   older portals without it fall back to status/consult.
5. Next: the event webhook to the AI WorkDeck backend for APNs (draft agreed: HMAC over `timestamp.rawBody`, ids only).

## Verification

- Contract check; `FirmReviewTests` (decoding, attention grouping, paragraph diff, portal allowlist incl. office paths and
  look-alike hosts, bearer header, error mapping, sign-off guard, account scopes, 20-locale strings).
- `FirmReviewFlowTests` (UI, skipped unless `AWD_FIRM_PORTAL_BASE` / `AWD_FIRM_TRIAL_CODE` are given): against a local copy of
  the portal server with synthetic matters behind a local HTTPS front whose CA is trusted only in the test simulator.
  Join (a foreign link is refused) → inbox → matter → reply → sign-off → signed PDF → confirm a call. The Debug-only
  `-AWDFirmUITest` seed supplies a synthetic account and redirects allowlisted portals to 127.0.0.1; Release builds do not contain it.
- Not covered yet: a real AI WorkDeck account approved on the production portal, push delivery, Android / HarmonyOS / WeChat.
