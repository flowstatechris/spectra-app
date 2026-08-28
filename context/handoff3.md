# Spectra UX Handoff 3

Created: August 27, 2026. App version **1.7.5**. Continues
[handoff2.md](handoff2.md) → [handoff.md](handoff.md).

Everything below is committed to local `main`. **There is no git remote** —
by the user's choice the repo lives only on this device. Do not nag about
pushing; there's nowhere to push.

`git show <hash>` for any commit's full diff — this doc references hashes and
does not repeat diffs.

## What this session built (newest first)

| Commit | What |
|--------|------|
| `1e16298` | Mark markdown render `nonisolated` (explicit off-main parse) |
| `705617a` | Expanded-header chat controls: icon circles flanking the orb |
| `f076b36` | In-app add profile (post-onboarding) |
| `5dda371` | (docs) handoff2 addendum |
| `ae71e79` | Pre-render + cache markdown so scrolling a finished thread can't freeze |
| `11fc711` | Cut main-thread load when scrolling during a stream |
| `fd47bfd` | Auto-follow only while pinned to the bottom (no scroll-jail) |
| `9fbb945` | Auto-scroll: key follow-to-bottom on O(1) values |
| `c1625f8` | Fix chat freeze on long streamed replies (§7) |
| `df6d160` | Tag version 1.7.5 |
| `fa66031` | §4 Multi-attachment |
| `a4ecc2a` | Profile switching + friendlier Activity copy |
| `d88608c` | §1 Consolidate UI-test login onto ASWebAuth flow; §2 mark done |
| `13d36fd` | §3 Rich-history reconciliation |

`eb9a275` and `e3431ee` at the base were pre-session (the user's own).

---

## ⚠️ THE UI FREEZE — exhaustive record (READ THIS BEFORE TOUCHING CHAT RENDER)

The chat froze on long streamed replies, then on scrolling. It was **not one
bug** — it was **five** distinct main-thread costs, each surfaced as the user
re-hit the freeze from a new angle and fixed in turn. All five are live
landmines: reintroducing any one re-creates the freeze. The overarching
**invariant**: *no markdown parsing on the main thread, and the live streaming
message never renders through `MarkdownText`.*

Everything below lives in `spectra-app/Views/ChatView.swift`,
`spectra-app/Views/MarkdownText.swift`, and
`SpectraCore/Sources/SpectraCore/ProfileSession.swift`.

### Symptom timeline (what the user actually reported)
1. "app froze" mid-generation on a big flight-search turn (many interleaved
   MCP / delegate-task tool calls + long streamed markdown).
2. After fix 1–2: froze specifically when **scrolling up/down _during_**
   generation.
3. After fix 3: no freeze during generation, but froze when **scrolling down a
   _finished_** long thread.
4. After fix 4–5: "no more freezes."

### Fix 1 — per-token markdown reparse (`c1625f8`)
- **Cause:** `MarkdownText.blocks` was a *computed property*
  (`Markdown.blocks(text)`), re-run on every SwiftUI body pass. While streaming,
  `message.text` grows one token at a time and the view re-renders per token, so
  the parser ran over the whole growing string every token → **O(n²)** on main.
- **Why the existing guard missed it:** there was already a plain-text fast path,
  but gated on `session.status == .speaking`. Any interleaved `tool.start` flips
  status `.speaking → .thinking` mid-stream (see `ProfileSession.handle`), so a
  long reply with tool calls kept falling back to `MarkdownText` → full reparse.
  `.speaking` renders as the header label **"Composing"**, which is why the
  frozen screenshot said Composing.
- **Fix:** expose `ProfileSession.streamingMessageID` (`public private(set)`, set
  on first token in `appendToStreamingMessage`, cleared at `message.complete`).
  Gate plain-vs-markdown on `message.id == session.streamingMessageID` — the
  exact "is this the live message" signal, immune to status churn. Live message =
  plain `Text`; markdown only after the stream ends.
- **Regression test:** `SessionSwitchTests` sibling
  `StreamingStateTests.testStreamingIDTracksTheLiveMessageThroughToolChurn`
  (feeds `message.start/delta` + `tool.start/complete` + `message.complete`,
  asserts the id tracks the live message through tool churn and clears on
  completion).

### Fix 2 — hidden O(n²) in the scroll trigger (`9fbb945`)
- **Cause:** `onChange(of: session.messages.last)`. `Message` is `Equatable`, so
  SwiftUI compares old-vs-new every update — walking the whole growing message
  **string** every token = a *second* O(n²), sitting right next to the parse.
- **Fix:** key the follow-to-bottom triggers on **O(1)** values instead:
  `onChange(of: session.messages.count)` (new rows) and
  `onChange(of: session.messages.last?.text.count)` (streaming growth). Same
  behavior, constant per-token compare.

### Fix 3 — programmatic scroll fighting the drag (`fd47bfd` + `11fc711`)
- **Cause A (scroll-jail, `fd47bfd`):** every token forced `scrollTo(.bottom)`,
  so you couldn't scroll up to re-read while the agent typed.
- **Fix A:** track `isPinnedToBottom` from a second `onScrollGeometryChange`
  (`visibleRect.maxY >= contentSize.height - 40`) and gate the follow handlers on
  it. Scroll up → holds position; return to within 40pt of the bottom → re-pins.
- **Cause B (freeze while scrolling during generation, `11fc711`):** even gated,
  when you scrolled back **down** mid-stream it re-pinned and fired a
  programmatic `scrollTo` **per token**, contesting the in-progress drag → main
  thread storm → freeze.
- **Fix B:** throttle the streaming follow-scroll to ~12/s via a **reference-type**
  timestamp holder (`FollowThrottle`, file scope in ChatView.swift) so updating
  the timestamp does **not** invalidate the view. `guard isPinnedToBottom,
  followThrottle.ready(minInterval: 0.08)`.

### Fix 4 — inline parse on scroll-in of a finished thread (`ae71e79` + `1e16298`)
- **Cause:** the block-split was memoized, but the **inline** parse
  (`AttributedString(markdown:)`, called per paragraph/heading/bullet/quote) still
  ran **in the view body on the main thread**, every time a `LazyVStack` row
  scrolled back into view. Scrolling a finished thread of big messages fired
  dozens of inline parses on main → freeze. (This is why generation-alone was
  smooth but scrolling the *finished* thread still froze.)
- **Fix:** `MarkdownText` was rewritten. `RenderedBlock` carries **pre-parsed
  `AttributedString`s** (both block split *and* inline). `RenderedBlock.render`
  (now `nonisolated`, `1e16298`) runs on a **detached task** off-main; the result
  is cached per message text in `MarkdownCache` (`NSCache`, `countLimit = 200`).
  A row scrolling back in reuses the cache; the view body only lays out
  already-parsed `AttributedString`s and never parses.

### Fixes NOT taken (deferred — freezes are gone, so YAGNI)
- **Coalescing delta tokens** in `ProfileSession.appendToStreamingMessage`:
  the whole `ChatView` body still re-evaluates on *every* streamed token
  (`@Observable` fires per token), and the live message's plain `Text` re-lays-out
  its full (growing) string each token — technically still O(n²) in plain-text
  layout. It has NOT been a problem in practice at v1.7.5. If a future very-long
  reply janks again, the real fix is to buffer incoming delta text and flush to
  `messages[idx].text` at ~20–30 fps instead of per token. That's the one
  remaining structural cost; reach for it only if measured.

### If you change chat rendering, re-verify BOTH:
1. Scroll up/down **during** a long generation (interleaved tool calls).
2. Scroll a **finished** long thread top-to-bottom.
User confirmed both smooth at 1.7.5.

---

## Other features this session (brief — see commits)

- **§3 Rich-history reconciliation** (`13d36fd`): `ProfileSession.timelineCache`
  (in-memory, per durable session id) keeps folded tool/approval/clarify rows
  across a switch-away-and-back; pure `reconcile(cached:server:)` uses user-turn
  count as the progress marker (server ahead ⇒ its text wins). Deferred:
  cross-launch persistence, tail-merge. Tests in `SessionSwitchTests`.
- **Profile switching** (`a4ecc2a`): "Switch profile" section in the Chat header
  sheet (`SessionSwitcherView`, >1 profile) + "Open Chat" in `ProfileDetailView`.
- **Friendlier Activity copy** (`a4ecc2a`): `ActivityItem.displayTitle` maps
  synthetic `turn`/`approval`/`clarify` to plain language, Title-Cases tool ids
  (`web_search` → "Web Search"). Tests in `ActivityTitleTests`.
- **§4 Multi-attachment** (`fa66031`): `Message.attachment` → `attachments: [ ]`
  (`Attachment` gained a stable `id`; legacy singular key still decodes → §10
  cold-launch safe). `ProfileSession` stages an array; `send()` prepends every
  file reference (images ride the server-side `image.attach` side-effect and
  already stack). Composer: multi-select `PhotosPicker` (max 4), chip strip,
  per-image full-screen via `UserAttachmentBubble`.
- **Version tagging** (`df6d160`): `MARKETING_VERSION` → 1.7.5; Settings → About
  renders `CFBundleShortVersionString`. **Bump this per release.**
- **In-app add profile** (`f076b36`): Profiles-tab `+` → `AddProfileSheet` lists
  backend profiles not yet added (multi-select → `addProfiles`);
  `AppState.refreshAvailableProfiles()` refetches the full list (after relaunch
  `availableProfiles` holds only added ones).
- **Expanded-header chat controls** (`705617a`): icon circles flanking the big
  orb — All Chats (left, opens switcher) / New Chat (right, fresh session,
  disabled mid-turn). Header tap is now gated to the **collapsed** state only
  (`compactHeader`) so it doesn't compete with the buttons. `HeaderPill` style
  was removed; `headerCircle` helper + inlined circle style.

## §1 / §2 status
- **§2 (on-device camera/files):** DONE — user validated by hand.
- **§1 (automated UI tests):** the two per-file login helpers were consolidated
  into `spectra-appUITests/UITestSupport.swift` `signIn(_:)`, retargeted from
  external Safari to `ASWebAuthenticationSession` (SafariViewService +
  SpringBoard consent). **It is UNVERIFIED** — carries a `ponytail:` marker; the
  element queries are contract-derived and never got a green live run, and the
  session-switch / notification-tap / composer UI tests were never written. User
  deprioritized. Live run needs `hermes serve` at `10.0.0.182:9119` + a booted
  sim (creds in the test: user `spectra`).

## Verification status at 1.7.5
- **SpectraCore `swift test --skip Live`: 43/43** (from 40 at handoff2 — +2
  `ActivityTitleTests`, +1 `StreamingStateTests`; reconcile tests already counted).
- App target **BUILD SUCCEEDED**; installed + launched clean on the booted sim
  (`iPhone 17 Pro`, UDID `6C8ED953-EAAD-4B5D-88C2-87E52A3D579C`, bundle id
  `cvictorin.spectra-app`).
- The freeze + scroll-jail fixes and the header layout were confirmed on-device
  by the user; header layout also screenshot-verified.

## Build / run loop (what worked this session)
`run.sh` targets plain "iPhone 17" and can boot a second sim → `booted`
ambiguous. Instead pin the UDID:
```
UDID=6C8ED953-EAAD-4B5D-88C2-87E52A3D579C
xcodebuild -scheme spectra-app -destination "platform=iOS Simulator,id=$UDID" \
  -derivedDataPath /tmp/dd build -quiet
xcrun simctl bootstatus "$UDID" -b
xcrun simctl install "$UDID" /tmp/dd/Build/Products/Debug-iphonesimulator/spectra-app.app
xcrun simctl launch  "$UDID" cvictorin.spectra-app
```
Big-orb header only shows at the top of a thread or in the first ~1.2s after
launch (`showingInitialHeader` window) — screenshot fast to capture it.

## Next steps (priority order)
1. **Nothing is required** — 1.7.5 is a clean, user-confirmed stopping point.
2. **Delta-token coalescing** (see "Fixes NOT taken") — the only remaining
   structural chat-perf cost. Do it if a very-long reply ever janks again.
3. **Automated UI tests (§1)** — the real outstanding debt. Verify `signIn`
   against the live backend, then write session-switch / notification-tap /
   composer + Stop tests. Remove the `ponytail:` marker once green.
4. **Rich-history persistence** — persist `timelineCache` across launches +
   tail-merge server deltas, if switching back to old sessions after relaunch
   losing the rich rows starts to matter.
5. **Version discipline** — bump `MARKETING_VERSION` each release; consider a
   `git tag vX.Y.Z` per version (user asked about UI version tagging, which is
   done; git tags were offered, not taken).

## Suggested skills for the next session
- `run` — launch/screenshot the app when validating UI (use the pinned-UUID loop
  above, not `run.sh`).
- `ponytail:ponytail` (house default) — keep the laziest-that-works bar; the RPC
  paths deliberately have no mock seam, don't add one speculatively.
- `mattpocock-skills:tdd` — only if picking up §1 (write the UI tests red-first).
- `mattpocock-skills:diagnosing-bugs` — if any freeze/jank recurs; the loop above
  ("symptom → isolate the exact main-thread cost → fix → re-verify both scroll
  scenarios") is the pattern that worked.
