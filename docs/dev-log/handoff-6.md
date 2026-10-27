# Spectra Handoff 6 — Remote access via Tailscale

Created: August 28, 2026. Continues [handoff5.md](handoff5.md) →
[handoff4.md](handoff4.md) → [handoff3.md](handoff3.md) →
[handoff2.md](handoff2.md) → [handoff.md](handoff.md).

**No code was written this session.** Nothing to commit — the working tree was
clean at start and is clean at end. `333ee77` (v1.8.5) remains HEAD. This is a
pure infrastructure/config session, which is exactly why it needs writing down:
the state lives on the machine and in the Tailscale admin console, not in git.

---

## The goal

Reach the Hermes Backend from the iPhone **off the LAN** — cellular, other
people's WiFi, anywhere — so Spectra stops being a house-only app.

## The result (current working configuration)

**Spectra's server field is now:**

```
https://macbook-pro.tail9d4d77.ts.net
```

No port. No IP. That one URL is the whole outcome of this session.

The chain behind it:

| Layer | State |
|-------|-------|
| Tailscale (macOS) | Installed via `brew install --cask tailscale-app`, signed in |
| Tailnet | `tail9d4d77.ts.net`, MacBook is `macbook-pro`, IPv4 `100.68.155.78` |
| HTTPS certificates | **Enabled** in the tailnet admin console (was off by default) |
| `tailscale serve` | `--bg --https=443 9119` — proxies 443 → `127.0.0.1:9119` |
| `hermes serve` | `--host 0.0.0.0`, port 9119 (unchanged, was already this way) |
| Spectra | Unchanged. Zero code, zero build-setting edits. |

Verified: `200` on `/api/health` over HTTPS, `ssl_verify_result: 0` (real
Let's Encrypt cert, not self-signed), `302` on `/` (the expected auth redirect).

---

## ⚠️ The ATS trap — read this before "simplifying" the setup

**The first attempt was to point Spectra at `http://100.68.155.78:9119`** — the
raw tailnet IP, same shape as the `http://10.0.0.182:9119` LAN address that has
always worked. **It fails**, with:

```
NSURLErrorDomain Code=-1022 "The resource could not be loaded because the
App Transport Security policy requires the use of a secure connection."
```

**Why:** App Transport Security exempts plain HTTP only for loopback,
link-local, and the RFC 1918 private ranges (`10/8`, `172.16/12`,
`192.168/16`). Tailscale hands out addresses from `100.64.0.0/10` — the
**CGNAT** range — which ATS does *not* treat as local. So `10.0.0.182` gets a
pass and `100.68.155.78` does not, despite looking equally "internal".

Confirm for yourself: the app has **no ATS exception at all**. Check
`spectra-app.xcodeproj/project.pbxproj` — the `INFOPLIST_KEY_*` entries include
`NSLocalNetworkUsageDescription` but there is no `NSAllowsArbitraryLoads` and no
`NSExceptionDomains`. The LAN setup has been running on ATS's built-in private-
range exemption this whole time.

**The rejected fix:** adding `NSAllowsArbitraryLoads = YES`. It's one line and
it definitely works, and it disables HTTPS enforcement for the entire app
permanently to solve a problem that TLS termination solves properly. Don't.

**The fix taken:** `tailscale serve` terminates real TLS with a Let's Encrypt
cert issued for the MagicDNS name. ATS is satisfied because the connection
genuinely *is* secure. No app-side change of any kind.

Bonus: `HermesRPCConnection.swift:87` already does
`comps.scheme = comps.scheme == "https" ? "wss" : "ws"`, so the WebSocket
upgraded to `wss://` on its own. Nothing to touch there either.

---

## Rebuild-from-scratch instructions

If the Mac is wiped, or you're setting up a second machine:

1. `brew install --cask tailscale-app`
   **Must run in a real Terminal window.** The installer needs `sudo`, and
   neither the agent's Bash tool nor Claude Code's `!` prefix provides a TTY for
   the password prompt — both fail with `sudo: a terminal is required`.
   Alternative, no brew: download `Tailscale-latest-macos.pkg` from
   `pkgs.tailscale.com/stable/` and double-click it.
2. Open Tailscale.app, sign in, confirm the menu bar shows **Connected**.
3. Enable HTTPS certs at `login.tailscale.com/admin/dns` → **HTTPS
   Certificates** → Enable. This is off by default and `tailscale serve` cannot
   issue a cert without it. Verify with:
   `/Applications/Tailscale.app/Contents/MacOS/Tailscale status --json` →
   `CertDomains` should be non-null.
4. `/Applications/Tailscale.app/Contents/MacOS/Tailscale serve --bg --https=443 9119`
5. Install Tailscale on the iPhone from the App Store, same account, connect.
6. Spectra → Change server → the `https://<machine>.<tailnet>.ts.net` URL.

The CLI is not on `PATH` — it lives inside the app bundle at
`/Applications/Tailscale.app/Contents/MacOS/Tailscale`.

To undo: `tailscale serve --https=443 off`.

---

## Known gaps — the next agent's likely work

**1. Not yet tested off-LAN.** Everything was verified from the Mac itself
(`curl` to the ts.net name) and the URL was handed to the user. The real proof —
**iPhone on cellular with WiFi off** — had not been run when this session ended.
Confirm that first before building on top of this.

**2. `hermes serve` does not survive a reboot.** `tailscale serve` config *does*
persist, so after a restart the proxy comes back up pointing at nothing and the
failure looks like a Tailscale problem when it isn't. If the Mac reboots while
you're away, you're locked out until you're physically back. A launchd job for
`hermes serve` was deliberately deferred, not forgotten — it's the obvious next
piece of work and the reason to do it is "get stranded once".

**3. Mac sleep.** A sleeping MacBook is an unreachable Backend. Not configured
yet. System Settings → Lock Screen / Battery → prevent sleep on power, or run
`caffeinate -s` alongside the server.

**4. The login flow was never exercised end-to-end over the tunnel.** The
`-1022` above happened *at* `/auth/native/token`, so the OAuth path is the one
that surfaced the problem and is the one to re-test. Spectra's loopback catcher
(`LoopbackCallbackServer.swift`) binds `127.0.0.1` **on the phone** and the
system browser is also on the phone, so the redirect never crosses the tunnel —
it should be fine. Should be. Verify.

---

## Note on the tailnet name

`tail9d4d77.ts.net` appears throughout this doc because it's load-bearing for
continuing the work. It is not a credential — reaching it still requires being
an authenticated member of the tailnet — but it is an identifier for the user's
private network. Keep in mind if this repo ever gains a remote. (Per handoff5:
there is no git remote, by choice.)

---

## Suggested skills

- **`ponytail`** — active throughout this session and the reason
  `NSAllowsArbitraryLoads` was rejected in favour of the platform feature that
  removes the need for it. Note where the ladder pointed: *rung 3, native
  platform feature*, not *rung 6, minimum code that works*. The laziest diff
  (one build setting) was not the laziest correct answer.
- **`run`** — `run.sh` builds, installs, and screenshots on the iPhone 17
  simulator. Note the simulator shares the Mac's network, so it will reach the
  ts.net URL trivially and **proves nothing about off-LAN access**. Only a
  physical device on cellular does.
- **`mattpocock-skills:diagnosing-bugs`** — if the off-LAN test fails. The
  useful first split is *DNS/tunnel* (does `curl` to the ts.net name work from
  the phone's browser?) versus *app* (does Spectra specifically fail?).
