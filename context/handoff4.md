# Spectra Handoff 4

Created: August 28, 2026. Continues [handoff3.md](handoff3.md) →
[handoff2.md](handoff2.md) → [handoff.md](handoff.md).

Everything in-repo below is committed to local `main`. **There is no git remote** —
the repo lives only on this device by the user's choice. Don't nag about pushing.

`git show <hash>` for any commit's full diff — this doc references hashes and
does not repeat diffs.

## What this session built (in-repo)

| Commit | What |
|--------|------|
| `531267f` | Fix login after server change (`notLoggedIn`); in-app "Change server"; SVG logo; folded-in prior WIP |

`af7b29c` (handoff3) is the pre-session base. Two files were already dirty at
session start and got folded into `531267f`: `ChatView.swift` (UIKit-backed
`AttachMenuButton` to kill the `_UIReparentingView` warning) and
`AuthPresenter.swift` (safer `ASWebAuth` presentation anchor).

---

## ⚠️ The login bug — root cause (the important part)

**Symptom:** after moving networks, entering valid credentials showed
`Login failed: notLoggedIn` on the LoginView.

**The hermes desktop update was a RED HERRING.** The entire app↔hermes auth
contract was verified intact against the updated hermes (v0.20.6): `/auth/native/
authorize` (302→/login), `/auth/native/token` + `/refresh` response shapes,
`/api/auth/ws-ticket`, `/api/ws` query-param ticket, `profiles.list`. Nothing
drifted. The user's two local hermes edits are also clean (both additive §11 APNs
push — see below).

**Actual cause (app-side, `SpectraCore/Sources/SpectraCore/AppState.swift`):**
`setBackend` replaced `self.auth` with a fresh `HermesAuthClient` but left the
**hydrated `rpc`** (from `hydrateFromCache`) bound to the *old* client. `login()`
adopted tokens into the new client, but `connectRPC()` reused the stale `rpc`
(`rpc ?? …`), so `mintTicket → validAccessToken` ran on the old client (tokens
nil) → `notLoggedIn`. Latent forever; only became reachable once the new "Change
server" flow let `setBackend` be called with a cached session live. Fix in
`531267f`: `setBackend` now disconnects + nils `rpc` and cancels its routers.

**Latent robustness issue (NOT fixed, flag for a future session):**
`HermesRPCConnection.connect()` sets state `.connected` immediately after
`task.resume()`, before the WS handshake actually succeeds. If the socket is
rejected *after* resume, `loadProfiles()`'s `profiles.list` awaits a continuation
that may never resolve → silent hang rather than a clean error. Consider awaiting
a handshake ack (or a first-frame/timeout) before marking `.connected`.

## Other in-repo changes (in `531267f`)
- **In-app "Change server":** `AppState.editBackend()` sets `phase = .needsBackend`;
  surfaced on LoginView and Settings → Backend. `BackendConfigView` prefills the
  current URL (`.onAppear`). This is what makes a changed LAN IP re-enterable —
  previously the IP box was reachable only during first-run onboarding.
- **SVG logo:** `LogoMark.imageset` now a vector `logo1.svg`, `template-rendering-
  intent: template` + `preserves-vector-representation`, tinted by `Theme.ink` →
  automatic light/dark. PNG removed. No Swift change (connect page already tinted).

## Known latent bug — `/api/status` shape drift (NOT in login path)
`HermesAuthClient.BackendStatus` decodes `/api/status` as
`{profiles, gateway_mode, auth_required, auth_flows}`, but the updated hermes
returns `{version, gateway_state, gateway_platforms, …}`. Nothing in the login/
connect path calls `fetchStatus`, so it isn't biting — but reconcile the decoder
(or the endpoint) before anything relies on it.

---

## Out-of-repo work done today (hermes-side, same machine)

Not in this repo, but part of the session and needed to run the app:

- **LAN serve rebind:** the manual `hermes serve` was bound to the old LAN IP
  (`10.0.0.182`, dead on the new network). Restarted **detached** bound to
  `0.0.0.0:9119` via `nohup … disown` (logs → `~/.hermes/logs/serve.out`) so it
  survives the Claude session. App backend is now the machine's current LAN IP.
- **Context-bloat fix:** every agent turn warned
  `AGENTS.md TRUNCATED: 95167 > 48000`. Cause: `terminal.cwd = .` in
  `~/.hermes/config.yaml` + `hermes serve` launched from `~/.hermes/hermes-agent`,
  so context-file discovery pulled the hermes repo's 95k contributor `AGENTS.md`.
  Fix: `terminal.cwd → ~/.hermes/workspace` holding a curated 4.5k `AGENTS.md`
  (working context only; persona stays in `~/.hermes/SOUL.md`). The 48k cap is the
  dynamic default = model_context × 4 × 0.06 (≈200k-token window).
- **SOUL.md autonomy gates:** added Dignity/Stewardship/Reverence → 🟢/🟡/🔴
  gates to `~/.hermes/SOUL.md` (conservative synthesis from existing directives +
  confirm-before-spend; user to tune if their real framework differs).
- These files hold the user's PII (Notion DB id, email, IMAP host) — read from
  disk (`~/.hermes/workspace/AGENTS.md`, `~/.hermes/SOUL.md`); not duplicated here.

## Suggested next steps
1. Reconcile the `/api/status` decoder drift (above).
2. Consider the `connect()` optimistic-`.connected` robustness fix (above).
3. Verify the end-to-end login on-device now that the serve is rebound + fix shipped.

## Suggested skills for the next agent
- **`ponytail:ponytail`** — house style (also encoded in the user's SOUL.md); laziest correct fix, root-cause over symptom.
- **`run`** — to launch/screenshot the app in the simulator when verifying a change (this session used `xcrun simctl io booted screenshot` to read the login error).
- **`code-review`** or **`simplify`** — before committing non-trivial diffs.
