# Handoff 7 — Push notifications: finish + clarify triggers, hermes serve reliability (v1.8.8)

## What changed

Spec §11 previously fired push on exactly one event (`approval.request`).
This session added the two triggers the spec had flagged as deferred/missing,
plus a reliability fix underneath all three.

**Client (this repo): no functional code changes.** `PushManager.swift`'s
`willPresent` (foreground-suppression) and `didReceive` (tap → `routeToChat
(profile:)`) already keyed purely off `userInfo["profile"]`, generic to any
push type. The 3 triggers differ only in server-side title/body — nothing
client-side needed to branch on a `type` field. Confirmed by reading
`PushManager.swift`, `AppState.swift`, `ProfileSession.swift` before touching
anything — this is why the diff here is docs + version only.

**Server (`~/.hermes/hermes-agent` — separate repo, committed locally there,
commit `c90bac6f2d`, not pushed to `origin`):**
- `_push_finish_notification(sid, payload)` — hooked into the one
  `message.complete` call site (main turn-completion path, inside
  `_run_prompt_submit`) that carries the real reply text. Fires only on
  `status == "complete"`; body = `tools.tts_text_normalize.prepare_spoken_text
  (text, max_chars=100)` — reused as-is, does exactly the markdown-strip +
  truncate this needed. The other 3 `message.complete` sites (pre-turn error,
  terminal error, background self-review summary) are deliberately not
  hooked.
- `_push_clarify_notification(sid, payload)` — hooked into `_block()` right
  after its `_emit(event, sid, payload)` call, scoped to `event ==
  "clarify.request"` only (the other 8 blocking-prompt types `_block()`
  serves — secret, sudo, terminal.read, etc. — are untouched). Body = the
  question text, or the first question's text for a batch clarify.
- Titles: `"<profile> — Reply ready"` / `"<profile> — Clarify"` (approval's
  existing `"<profile> — Approval needed"` untouched).
- The 3 `register_gateway_notify(...)` call sites that wire up the approval
  push had bare `except Exception: pass` — the single most likely place the
  pre-existing approval trigger could silently never fire. Upgraded all 3 to
  `logger.debug(...)` so a registration failure is at least discoverable in
  logs going forward, rather than invisible.
- New `tests/gateway/test_tui_push_notifications.py` (20 tests) covering all
  three `_push_*_notification` helpers plus the `_block()` clarify-only
  scoping. Full regression pass across this file + the pre-existing approval
  redaction and clarify tool/session suites: **75 passed, 0 failed.**

**Reliability:** new `~/Library/LaunchAgents/ai.hermes.serve.plist`
(`Label: ai.hermes.serve`) — auto-restarts `hermes serve` on crash
(`KeepAlive`) and boot (`RunAtLoad`). This is a *different* job from the
existing `ai.hermes.gateway` plist (which runs `hermes_cli.main gateway run`,
a different process entirely — restarting one never reloaded the other, per
handoff4's original gotcha). Before this session `hermes serve` was a
manually-started orphan (PPID 1, `nohup … disown`), which is exactly what
handoff6 flagged as a known gap. Verified live: killed the process with
`-9`, launchd respawned it within `ThrottleInterval` (30s), port 9119 came
back up. No sleep-prevention (`caffeinate`) was added by design — the Mac can
still sleep, push just won't arrive while it's asleep. `ai.hermes.gateway`
itself was confirmed *not currently loaded* at session start (not a
coexistence risk here, just worth knowing).

## Small naming note

The manually-started process's logs were actually going to
`~/.hermes/logs/serve.out` (confirmed via `lsof`), not `serve.log` as the
convention elsewhere suggested — `serve.log` was a stale file from a day
earlier. The new plist targets `serve.log`/`serve.error.log` (matching
`ai.hermes.gateway`'s split convention) going forward; `serve.out` is now
dead weight from the old manual invocation.

## Update — live-device follow-up (same day)

The user tested on a real device: **all three triggers fire correctly.**
Tapping a notification to route into the chat crashed the app, though —
Xcode console showed an uncaught `com.apple.coreaudio.avfaudio` exception,
`'player did not see an IO cycle'`, terminating the process. (The keyboard
auto-layout warnings and pasteboard error in the same log dump were noise;
that one line was the actual crash.)

Root cause, confirmed by direct code match: `Cuelume.play()`
(`SpectraCore/Sources/SpectraCore/Cuelume.swift`) plays `.scan` on
`message.complete` ("response finished") and `.arrival` on
`approval.request`/`clarify.request` — literally the three push triggers
just added. `.ambient` audio session category tears the engine down while
backgrounded; the old `play()` restarted it and called
`AVAudioPlayerNode.play()` in the very same tick, before any IO cycle —
exactly the crash pattern, hit reliably by a notification tap resuming
straight into a cue-playing event.

**First fix attempt (`8ce97cc`) was insufficient — same crash recurred.**
It gated `play()` on `engine.isRunning`, assuming false meant "cold, skip."
Wrong: iOS can leave `engine.isRunning` reporting **true** across a
background→foreground cycle even though the real hardware IO was torn
down while suspended — nothing was listening for that, so the flag never
got corrected, the guard's condition never fired, and `node.play()` hit
the same crash again on the same line.

**Fix #2 (`03154fd`)** stopped trusting `engine.isRunning`. Added an
explicit `isWarm` flag, true only via a one-shot `installTap` confirming a
genuine CoreAudio render callback, invalidated on
`UIApplication.didEnterBackgroundNotification`, re-confirmed on
`willEnterForegroundNotification`. Correct for plain backgrounding — but
**crashed a third time**, this time reported while the user was on an
active FaceTime call, with a second, worse symptom: Spectra's audio was
glitching the FaceTime call itself, persisting until the user left the
app.

**Why fix #2 still missed it:** an `AVAudioSession` interruption (a call,
Siri, an alarm taking the audio session) isn't tied to app backgrounding
at all — it can happen while Spectra stays fully foregrounded the entire
time (tapping a notification while already mid-call). Fix #2 only
listened for `UIApplication` background/foreground, so `isWarm` never got
invalidated and the exact same crash fired on the exact same line.
Separately: even having Cuelume *try* to activate its own audio session
and start the engine while a call owns the hardware route is itself
disruptive to the call — that's the glitch report, independent of
whether it happens to crash.

**Fix #3 (`2fbca02`):** added `AVAudioSession.interruptionNotification`
handling (`.began` invalidates `isWarm`, `.ended` re-confirms it)
alongside the existing lifecycle observers, plus a `shouldStayQuiet()`
guard using Apple's own `secondaryAudioShouldBeSilencedHint` — true for
the entire duration a call/Siri/alarm owns audio, not just around the
edges. Both `play()` and the engine-(re)start path now bail out on it
*before touching the engine at all*, so Cuelume stops interfering with a
live call rather than just failing more gracefully into it. New tests
use a test-only override (the real hint reflects live system state and
can't be forced from a test process) to confirm both paths skip
correctly. Full suite (60 tests) green; `nm` confirms the new interruption/
silence-hint symbols are in the built binary.

**Honest limit, stated plainly:** all three symptoms (the crash, the
call-audio glitch, and each specific fix) were diagnosed and fixed from
code + unit tests + build/symbol inspection — none of it can exercise a
real concurrent FaceTime call with actual hardware audio routing in this
environment. This needs a live retest **specifically while on a call**,
not just "does the app still route to chat without crashing."

## What was NOT done — validate this next

The existing `approval.request` push was **not** re-validated against a real
approval on a physical device before the above test (that needs the phone,
which the earlier part of this session didn't have). Code review found no
actual bug in the trigger/registration path itself — `register_gateway_notify`'s
session-key registration matches the lookup key used elsewhere (`session["session_key"]`,
same value at all 3 call sites), and `apns_sender.py` logs real send failures
(`logger.warning`) rather than swallowing them. **Now confirmed live**: per
the update above, all three triggers do fire on a real device. Foreground-
suppression, exact title/body content, and finish's no-push-on-error/
interrupted behavior still haven't been explicitly checked one-by-one —
worth a quick pass now that the crash is out of the way.

Also worth a cheap check while there: per handoff6, off-LAN/cellular chat
access was never verified. APNs delivery itself doesn't depend on that (it's
phone ← APNs ← Hermes, independent of Tailscale) — so the push banner should
still arrive on cellular even if tapping it to load the chat is the
pre-existing unverified gap.

## Explicitly deferred — next up after this

**Interactive notification actions** (Approve/Deny buttons, or a quick-reply
field for Clarify, directly on the push banner) were explicitly scoped out
of v1.8.8. Spec §11 has called this "a stretch goal, not a v1 blocker" since
the original build; it remains the next real step for notifications now that
all three trigger types exist. Tapping still just opens the app to that
profile's chat, where the Approval/Clarify card already renders inline.

## Files touched

- `~/.hermes/hermes-agent/tui_gateway/server.py` — 3 new push helpers, 2 new
  hook points, 3 upgraded exception logs (committed locally, not pushed).
- `~/.hermes/hermes-agent/tests/gateway/test_tui_push_notifications.py` — new.
- `~/Library/LaunchAgents/ai.hermes.serve.plist` — new, host config, not
  tracked in either repo.
- `context/spectra-full-spec-v2.md` §11 — trigger list updated.
- `spectra-app.xcodeproj/project.pbxproj` — `MARKETING_VERSION` 1.8.5 → 1.8.8.
