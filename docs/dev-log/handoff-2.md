# Spectra UX Handoff 2

Updated: August 27, 2026. Continues [handoff.md](handoff.md).

## What this session built

Step 2 from handoff.md ("Bring Hermes chat sessions into Spectra") is done, plus
handoff §5, §6, and a header fix. All incremental — extends the existing
`AppState`/`ProfileSession` architecture, no new frameworks.

Commits (newest first), read the messages/diffs for detail:

- `b15e726` Keep `recordActivity` private behind a `#if DEBUG` test shim.
- `15210e0` §6 Attention system: one shared `ProfileSession.attention` signal +
  notification tap-routing.
- `91e2d11` §5 Activity continuity: representative feed, cross-launch
  persistence, deep-link flash.
- `5d553e6` Halve the expanded Chat header (user ask).
- `55b0cbe` Handle `session.reclaimed`.
- `b5e0788` §2b Session switcher UI.
- `c2a2ffa` §2 Session continuity backbone (durable `stored_session_id`).

`git show <hash>` for each. Working tree is clean; everything is committed.

## Wire contract verified this session

Confirmed against the local gateway source (not just asserted):
`/System/Volumes/Data/Users/chrisvictorin/.hermes/hermes-agent/tui_gateway/methods_session.py`
and `.../tui_gateway/server.py`.

- `session.create` → top-level `session_id` (runtime) + `stored_session_id`
  (durable) + `messages` + `info`.
- `session.list` (param `profile`) → `sessions:[{id, resolved_id?, title,
  preview, started_at, message_count, source}]`. Resume targets the item `id`.
- `session.resume` (param `session_id` = durable id, `omit_messages` optional) →
  new runtime `session_id` + `stored_session_id` + `messages`.
- Gateway broadcasts `session.reclaimed` `{session_id, stored_session_id,
  reason}` for `idle_timeout` / `lru_evict` / `ws_orphan_reap`. It carries the
  dead runtime id, so it routes by `serverSessionID` match into
  `ProfileSession.handle`.
- History rows are `{role, text}` for user/assistant; tool rows are
  `{role:"tool", name, context, args}`.

## Key design decisions (so they aren't relitigated)

- **Reconnect/relaunch resume keeps the local timeline** (`omit_messages:true`) —
  Spectra's richer ToolActivity/Approval/Clarify rows aren't in Hermes history.
  **Explicit switch/New Chat DOES replace** messages via `mapHistory` (user asked
  to change conversations).
- `mapHistory` (v1) keeps only user/assistant text rows; tool/system rows are
  skipped, not reconstructed. Full-fidelity reconciliation is deferred.
- `session.reclaimed` reuses `resetForReconnect()` (same teardown).
- Switching is gated mid-turn/mid-approval (`canSwitchSessions`); listing stays
  available, only the actions disable.
- Persisted Activity rows still non-terminal from a dead session resolve to
  `.interrupted` on restore (no stale "Working"/"Waiting").
- `attention` = pending approval (outranks) or clarify; running tools are NOT
  attention.

## Verification status

- `swift test --skip Live`: **37/37 pass** (was 34 at handoff.md; +8 new in
  ReconnectTests, SessionSwitchTests, ActivityNavigationTests, PersistenceTests,
  AttentionTests).
- `xcodebuild ... 'iPhone 17'`: BUILD SUCCEEDED at each step; installs + launches
  clean in the booted sim. User confirmed the switcher + header UI by hand.
- Pre-existing warnings unchanged (`HermesRPCConnection.Event` `[String:Any]?`
  Sendable; `AuthPresenter` deprecated `ASPresentationAnchor()`).

## Coverage gap (thinnest spot)

The network paths — `listSessions` / `newSession` / `switchTo` and the
notification tap — are only unit-tested at their pure helpers (`mapHistory`,
`attention`, `routeToChat`). `HermesRPCConnection` is a concrete actor with **no
mock seam**; this matches how `session.create` was always covered (live suite +
on-device). Don't build a mock harness speculatively — see §1 below.

## Open items (from handoff.md, priority order)

### 1. Fix the UI-test auth helper (unblocks real UI coverage)
Still nominated first. The shared login helper expects `XCUIApplication(
bundleIdentifier: "com.apple.mobilesafari")`; the flow is now in Spectra's
presented auth UI, so the Activity deep-link test fails before asserting.
Rewrite it, then add UI tests for: session switch (list/new/resume), the
notification-tap route, and composer multiline + Stop.

### 2. On-device composer/camera checks (§3 in handoff.md) — DONE (manual)
Validated by hand on-device Aug 27 2026: camera and Files both work
(capture/preview/send + file attach). Not automated (needs a physical device;
sim can't drive the camera), but no longer an open risk.

### 3. Rich-history reconciliation (deferred from §2)
When it matters: keep the local ToolActivity/Approval/Clarify timeline keyed by
durable session id and reconcile with Hermes history on resume, instead of the
v1 text-only `mapHistory`.

### 4. Lower-priority handoff.md leftovers
§4 multi-attachment (only if real usage needs it); §7 profile streaming only if
freezes recur. Activity standalone rows render `turn`/`approval`/`clarify` as the
mono tool-name — tweak `ActivityRow` if you want friendlier copy.

## Important locations

Unchanged from handoff.md, plus:
- `SpectraCore/Sources/SpectraCore/ProfileSession.swift` — `storedSessionID`,
  resume-preferring `ensureSession`, `listSessions`/`newSession`/`switchTo`/
  `mapHistory`, `Attention`, `session.reclaimed` case.
- `SpectraCore/Sources/SpectraCore/AppState.swift` — Activity persistence/restore,
  standalone-row inserts, `routeToChat`/`chatRouteToken`, `recordActivityForTest`.
- `spectra-app/Views/SessionSwitcherView.swift` — new picker sheet.
- `spectra-app/Views/ChatView.swift` — tappable header + sheet, halved header,
  deep-link highlight.
- `spectra-app/Views/PushManager.swift` — `didReceive` tap route.
- `spectra-app/ContentView.swift` — `chatRouteToken` → Chat tab.

## Suggested skills for the next session

- `mattpocock-skills:tdd` — for item 1, write the UI tests red-first.
- `ponytail:ponytail` (default here) — keep the laziest-that-works bar; the RPC
  paths deliberately have no mock seam, don't add one speculatively.
- `run` — to launch/screenshot the app when validating UI changes.

---

## Session 3 addendum (Aug 27 2026, v1.7.5)

Shipped on top of the above, all committed to local `main` (no git remote —
everything lives on-device by choice):

- **Profile switching** (`a4ecc2a`): "Switch profile" section in the Chat header
  sheet (>1 profile) + "Open Chat" in profile detail. Confirmed working.
- **§4 multi-attachment** (`fa66031`): `Message.attachment` → `attachments: [ ]`
  (legacy singular still decodes); stage/remove several, send together.
- **Friendlier Activity copy** (`a4ecc2a`): `ActivityItem.displayTitle`.
- **Version tagging** (`df6d160`): `MARKETING_VERSION` → 1.7.5; Settings → About
  already renders it. Bump this per release.

### ⚠️ Chat streaming performance — a recurring freeze, now fixed (special note)

Long streamed replies with interleaved tool calls froze the app. It was NOT one
bug — it was **four** separate main-thread costs, fixed in sequence as the user
re-hit the freeze from different angles. Any future chat-render change should
respect these; they will re-introduce the freeze if regressed:

1. `c1625f8` — `MarkdownText.blocks` was a computed property → the whole growing
   message re-parsed every streamed token (O(n²)). The plain-text fast path was
   gated on `status == .speaking`, which interleaved tool calls flip to
   `.thinking` mid-stream, defeating it. Fix: gate on `message.id ==
   streamingMessageID` (exposed read-only) — the live message renders as plain
   text, no markdown until complete.
2. `9fbb945` — `onChange(of: messages.last)` ran `Message`'s Equatable compare
   (walks the whole growing string) every token = a second O(n²). Fix: key
   follow-scroll on O(1) values (`messages.count`, `last?.text.count`).
3. `11fc711` — follow-scroll fired a programmatic `scrollTo` per token, fighting
   an in-progress drag (froze when scrolling during generation). Fix: throttle
   to ~12/s via a reference-type timestamp (no view invalidation).
4. `ae71e79` — scrolling a FINISHED thread still froze: each big message
   re-parsed inline markdown (`AttributedString(markdown:)` per block) in the
   view body every time a LazyVStack row scrolled back in, on main. Fix:
   `RenderedBlock.render` (block + inline) runs on a detached task and is cached
   (NSCache, 200 msgs); the body only lays out pre-parsed AttributedStrings.

Invariant to preserve: **no markdown parsing on the main thread**, and the live
streaming message renders plain (never through `MarkdownText`). Test both:
(a) scroll up/down *during* a long generation, (b) scroll a *finished* long
thread. User confirmed both smooth at v1.7.5.

Deferred (not needed — freezes gone): coalescing delta tokens in `ProfileSession`
so the UI updates ~20-30×/s instead of per-token. Reach for it only if the
per-token full-`ChatView` re-render ever becomes the bottleneck again.

### Still open
- **Automated UI tests (handoff §1)** — `signIn` helper rewritten but UNVERIFIED
  (ponytail-marked in `UITestSupport.swift`); session-switch / notification-tap /
  composer UI tests still unwritten. User deprioritized.
- **In-app "add profile"** — profiles are only choosable at onboarding; no
  post-onboarding add UI. Offered, not taken.
