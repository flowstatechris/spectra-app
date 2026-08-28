# Spectra Handoff 5

Created: August 28, 2026. Continues [handoff4.md](handoff4.md) →
[handoff3.md](handoff3.md) → [handoff2.md](handoff2.md) → [handoff.md](handoff.md).

Everything below is committed to local `main`. **There is no git remote** — the
repo lives only on this device by the user's choice. Don't nag about pushing.

`git show <hash>` for any commit's full diff — this doc references hashes and
does not repeat diffs.

## What this session built

| Commit | What |
|--------|------|
| `a491c6a` | Smooth chat UI: shimmer, pinned answers, spacing tokens (v1.8.3) |

`7115d90` (Cuelume SFX, v1.8.2) is the pre-session base. Working tree was clean
at session start. `MARKETING_VERSION` bumped 1.8.2 → 1.8.3 in the same commit,
per the convention that feature commits name their version.

Session was a UI-smoothness pass driven from screenshots: spacing/alignment
audit across all four tabs, transitions, and a ChatGPT-style "thinking" shimmer.

---

## ⚠️ The message-ordering bug — root cause (the important part)

**Symptom:** the agent's final answer rendered *above* the tool rows that
produced it, so you had to scroll up through a forest of tool calls to read it.

**Cause** — `SpectraCore/Sources/SpectraCore/ProfileSession.swift`:

- `appendToStreamingMessage` (~line 472) creates the agent message on the
  **first delta** and appends it at the then-current end of `messages`.
- Tool rows (`tool.start` → `startTool`) append *after* it as the turn runs.
- `message.complete` (~line 361) looks up that same id and writes the finished
  text back into its **original index**.

So the answer is positioned where the agent first opened its mouth, not where it
finished. The comment at line ~349 (`message.start` sets `streamingMessageID =
nil` so "tool rows … stay in their true chronological position") shows this was
half-fixed already: it handles tools emitted *before* the first token, but
nothing handled tools arriving *after* it — the common case.

**Fix — presentation layer, not the model.** `pinAnswersToTurnEnd` in
`spectra-app/Views/ChatView.swift`, composed into `threadItems`, moves each
turn's last agent `.plain` message to the end of its turn. The model keeps true
chronology, which matters for persistence, the Activity feed and `chatScrollTargetID`
deep links.

Two constraints that are deliberate, each with a test:

- **Only the turn's *last* agent message moves.** Narration that introduces a
  tool ("Loading the flight skill first:") must stay above it.
- **Pinning is per-turn, not thread-wide.** Global pinning would make a completed
  answer visibly jump when the next prompt arrived.

**Emergent interaction, caught by a test rather than the simulator:** with the
answer pinned last, a status run is no longer the trailing item, so it stops
qualifying as "live" and stops shimmering. Net effect is one shimmer per turn
(the answer row) instead of two competing ones. This is better than the
designed-on-purpose alternative, but it *emerged from composing two rules* —
`ThreadItemsTests/pinnedAnswerLeavesNoLiveStatusRun` pins it down so it can't
silently revert. Don't "fix" that test without understanding it.

---

## Other changes in `a491c6a`

**Streaming no longer shows raw markdown.** The streaming row shimmers the
status label (`OrbView.label(for:connectionState:)`, so the row and header can't
disagree) and cross-fades to the rendered answer. The 0.3s fade is not
cosmetic — `MarkdownText` fills `blocks` via an off-main `.task`, so it renders
*empty* for a beat after mounting; a hard cut would show shimmer → blank → pop.

**Auto-scroll rewired.** The old follow keyed on `messages.last?.text.count`,
which worked only because the visible row grew per token. It no longer does —
the streaming row is one fixed-height line, and the thread only grows when the
rendered answer replaces it. New follow fires on `streamingMessageID` going nil.
It carries a **120ms sleep** marked `ponytail:` — the markdown parse has no
completion signal to hook. If it lands short on a very long answer, that's the
line to revisit (plumb readiness out of `MarkdownText`).

**Alignment bug found during the audit:** the chat header used 18pt horizontal
padding compact and 24pt expanded, so it slid sideways on every scroll-triggered
collapse. Both are `Space.gutter` (20) now, shared with the other three tabs.

**Design tokens** added to `Theme.swift`: `Radius.sm/md/lg/xl` (10/14/18/22) and
`Space.gutter`/`Space.row`. 22 scattered radius literals across the four tabs
mapped onto the scale; nothing moved more than 2pt.

**Shimmer** (`.shimmering(_:)` in `Theme.swift`) is a moving gradient handed to
`foregroundStyle`, driven by `TimelineView(.animation)` the same way the vendored
`ThinkingOrb` drives itself. Deliberately **not** overlay+mask — a mask forces an
offscreen pass every frame. Honours Reduce Motion. The modifier owns the text
colour, so call sites must not set their own `foregroundStyle` (an inner one wins
and hides the sweep) — this is documented at the extension.

**Status runs**: consecutive `.status` messages fold into runs; superseded runs
collapse behind the same chevron affordance `ToolActivityRow` uses.

**Transitions**: row insert (fade + rise), tool/status detail expand,
approval/clarify cards, the collapsed approval chip, send↔stop swap.

---

## Verification state

- `xcodebuild -scheme spectra-app -destination 'id=<iPhone 17 Pro sim>' build` — **passes**.
- 8 tests in `spectra-appTests/spectra_appTests.swift` — **all pass**.
  Simulator note: the iPhone 16 sims on this machine are on an older runtime that
  doesn't match the deployment target; use an iPhone 17 / iPhone Air sim
  (`xcodebuild -scheme spectra-app -showdestinations` for current ids).

**Verified on device by the user** at the end of the session — the shimmer,
the cross-fade to the rendered answer, and the pinned answer ordering all
behave correctly on a real Hermes turn. The repro throughout was the
flight-search case (`BOS→HND`, hits the `/flight` skill and several
`mcp soar flights` calls), which is what produced the original bug screenshots.

The automated tests cover the ordering and grouping rules against synthetic
message arrays; device behaviour rests on that manual confirmation rather than
on a UI test.

---

## Open threads / next steps

1. **The 120ms scroll follow on very long answers.** Confirmed working in normal
   use, but the sleep is a guess at when the off-main markdown parse lands — a
   much longer answer is the case that could still land short.
2. **Shimmer pace** (1.7s sweep, `TextShimmer.period` in `Theme.swift`) is a
   taste value — left at the default, tune if it reads fast or slow.
3. **"Composing…" on a long answer** — the user traded visible token-by-token
   progress for a clean reveal. If a multi-second wait reads as *stalled*, the
   status lines ticking underneath are what carry it; reconsider if they don't.
4. **User's own idea, not acted on:** changing Jarvis so thinking/status
   messages aren't sent at all. Backend change, out of scope this session. The
   run-collapsing makes them cheap to ignore, so see whether it's still wanted.
5. **Untouched latent issue from handoff4:** `HermesRPCConnection.connect()`
   sets `.connected` immediately after `task.resume()`, before the WS handshake
   succeeds → possible silent hang instead of a clean error. Still open.

---

## Suggested skills for the next agent

- **`run`** — to launch the app when picking this up; the chat UI is the surface
  every open thread below touches.
- **`ponytail:ponytail-debt`** — harvests the `ponytail:` markers. This session
  added one worth tracking (the 120ms scroll sleep) alongside the existing ones.
- **`mattpocock-skills:diagnosing-bugs`** — if the live run surfaces ordering or
  scroll problems, since the last one had a non-obvious root cause two layers
  from the symptom.
- **`code-review`** — if picking up cold and wanting a second opinion on
  `a491c6a` before building further.
