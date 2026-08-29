# Spectra — Full Build Spec (v2, wire-verified)

Native iOS + macOS client for Hermes Agent. Open-source, MIT licensed, bring-your-own-backend. Point it at any `hermes_cli.main serve` instance and get a real app instead of a text thread.

Tagline: *Any Hermes instance. Your phone. One app.*

This version corrects three architectural assumptions in v1 against actual server source tracing — see §2 changelog note.

---

## 1. Platform & tech constraints

- **SwiftUI only.** `@Observable` (not `ObservableObject`), iOS 17+ / macOS 14+ minimum target — actual target should be iOS 26+ to get Liquid Glass and ActivityKit for free.
- No third-party dependencies beyond: `CryptoKit`, `Network`, `AuthenticationServices`, and **ThinkingOrbsKit** (SPM, MIT licensed — see §7).
- No React/web components, no hybrid wrapper. Design language may be *inspired* by web references but everything is re-implemented natively.
- Liquid Glass: take it for free on all standard system components (NavigationBar, TabBar, Toolbar, Sheets, Toggles, Sliders — automatic on Xcode 26 recompile). Custom surfaces we own — the orb, approval/clarify cards, message bubbles — get a deliberate glass treatment, not the default.
- Shared package for core logic (auth, models, networking) + separate App targets for macOS (`MenuBarExtra`) and iOS (standard `App`).

---

## 2. Server contract (wire-verified against a real running Hermes instance)

Base URL = one `hermes_cli.main serve` process. Everything below is scoped to that one process.

**v2 correction note:** v1 assumed approval/decision UI could run over the passive `/api/events` feed. Verified false — approvals and clarify-questions are JSON-RPC on **`/api/ws`**, a third connection type distinct from `/api/pty` (raw terminal bytes) and `/api/events` (structured status stream). See §2.5.

### 2.1 Auth (RFC 8252 native-app OAuth, PKCE)
- `GET /auth/native/authorize?provider=&code_challenge=&code_challenge_method=S256&redirect_uri=&state=` — opens in **system browser**, not embedded webview. `redirect_uri` must be `http://127.0.0.1:<ephemeral-port>/callback` (loopback-only, enforced server-side).
- `POST /auth/native/token` — body `{code, code_verifier}` → `{access_token, refresh_token, token_type, expires_at, provider, user_id}`.
- `POST /auth/native/refresh` — body `{refresh_token, provider}` → same shape, or `401 {error:"session_expired"}` (must re-login, don't retry) or `503` (provider unreachable, retry later).
- Requires server-side `dashboard.basic_auth` configured in `~/.hermes/config.yaml` with an **explicit `secret`** (unset = random per-restart = every client logged out on every server restart).
- Non-loopback bind (`--host <tailscale-ip>`) **requires** this auth mode to be active; `--insecure` is a documented no-op post-hardening.

### 2.2 Profile discovery
- `GET /api/status` — **public, no auth required**, even on a gated bind. Returns `{profiles: [String], gateway_mode: String}`. Safe to call before login (populates onboarding picker).
- **Confirmed: this is genuinely all the metadata available over HTTP.** Richer per-profile data (`description`, `model`, `provider`, `skill_count`) exists server-side (`ProfileInfo` via `list_profiles()`) but is never called from `web_server.py` — CLI-only, not network-accessible. Don't build UI that assumes this data is fetchable; the Profiles-tab detail view is name-only unless the server is patched to expose it.

### 2.3 Session (chat) transport — `/api/pty`
- `/api/pty?profile=<name>&attach=<stable-channel-id>&ticket=<val>` — **the only correct connection param is `attach=`, not `resume=`.** `attach=` puts the session on the server's keep-alive registry: detaching (WS drop) does NOT kill the PTY — it buffers into a ring buffer until 30 min (`ttl=1800s`) of idle detachment, then reconnecting with the same `channelID` replays the buffered tail and resumes live.
- This is a **raw terminal byte stream** — chat text and file-attachment slash commands are sent as plain UTF-8 text here (§2.6), and terminal output (including your plain-monospace rendered text) arrives as raw bytes/ANSI.
- **Keepalive: confirmed, no client action needed.** The server's receive loop has no idle timeout — holding the socket open sending nothing is sufficient to keep it alive. On **loopback**, WS ping is explicitly disabled server-side (avoids false-positive disconnects from event-loop stalls during long tool calls). On **non-loopback (Tailscale) binds**, standard WS ping/pong is active (default 20s/20s) — `URLSessionWebSocketTask` answers this automatically at the OS layer, no app code required. Just don't let iOS suspend the socket for >20s of silence while foregrounded, or the ping trips and you go through reconnect/replay (harmless — PTY persists 30 min past detach regardless).
- **Hard server-wide cap: 16 concurrent PTY sessions per server process**, shared with every other client hitting that process (Electron desktop tabs included, not per-user or per-profile). When full, the server evicts the oldest *idle* (detached) session to make room; only rejects (`RegistryFull`, WS close code 1011) if every session is actively attached.

### 2.4 Structured events — `/api/events`
- `/api/events?channel=<id>&ticket=<val>` — pure subscribe-only broadcast of structured JSON events. **Only carries data when a live `/api/pty` session on the same channel is actively running and emitting** — not a passive ambient feed on its own; requires the paired PTY connection.
- Event types (verified against `tui_gateway/server.py`): `turn.start`, `turn.started`, `turn.end`, `turn.error`, `tool.start`/`tool.started`, `tool.complete`, `tool.output_risk`, `delta` (streaming tokens), `text`, `reasoning.available`, `status.update`, `hello`, `hb` (heartbeat), `gateway.ready`, `interrupt`/`interrupt.ack`, `session.seeded`, `shutdown`/`shutdown.ack`, `reload_mcp`, `error`.
- No `cron.fired` or Goals-DB-change event exists on this transport — cron output reaches the user only via configured delivery channels (iMessage/Telegram/etc.), not this socket.
- Use this stream to drive orb state (§7).

### 2.5 Approval & clarify — `/api/ws` (JSON-RPC — separate connection from §2.3/§2.4)
**This is the corrected mechanism for both approval gates and decision cards.** Both are real, implemented, server-driven — Spectra does not parse plain text or tool output for this.

**Approval** — server pushes:
```json
{
  "type": "approval.request",
  "sid": "<session-id>",
  "command": "<redacted command string>",
  "choices": ["once", "session", "always", "deny"],
  "smart_denied": false
}
```
`choices` is dynamic: `["once","deny"]` when `smart_denied`, otherwise escalating up to `["once","session","always","deny"]` gated by server-side `allow_session`/`allow_permanent` flags. **Not a fixed binary approve/deny — the card must render however many choices the server actually sends.**

Client responds via RPC method `approval.respond`:
```json
{"method": "approval.respond", "params": {"session_id": "...", "choice": "once"|"session"|"always"|"deny", "all": false, "request_id": "..."}}
```

**Clarify** (a distinct mechanism — this is literally the same tool Jarvis uses to ask the user things) — server pushes a `clarify.request`, client responds via `clarify.respond`, which supports a batched `answers` dict for replaying multiple pending questions after a reconnect.

**Both are replay-safe on reconnect** — pending approval/clarify requests are re-delivered to a client that reconnects mid-question rather than being lost.

### 2.6 File attachments — confirmed two-step
**Step 1 — REST upload:**
```
POST /api/chat/image-upload?profile=<name>
Content-Type: application/json
{ "data_url": "data:image/png;base64,<...>", "filename": "photo.png" }
```
→ `{ "ok": true, "path": "/Users/.../images/dashboard_20260826_..._photo.png", "name": "...", "bytes": N, "mime_type": "image/png" }`

**Step 2 — reference it on the already-open `/api/pty` socket as plain text:**
```
/image /Users/.../images/dashboard_20260826_..._photo.png
```
Not JSON-RPC, not binary framing — literal text the TUI's slash-command parser reads. The `?profile=` query param on upload must match the session's profile name (files land in that profile's `HERMES_HOME/images/`).

### 2.7 Ticket scoping — confirmed unscoped
`POST /api/auth/ws-ticket` mints a ticket carrying only `{user_id, provider, minted_at}` — no endpoint field. `_ws_auth_ok()` performs no per-endpoint check. **A single minted ticket is valid interchangeably across `/api/pty`, `/api/console`, `/api/ws`, `/api/pub`, and `/api/events`.** Mint a fresh one immediately before each connect attempt regardless of which endpoint it's for — never cache or reuse.

### 2.8 Session eviction — confirmed not reliably detectable
On any `/api/pty` reattach, a **true resume** sends the buffered snapshot then a force-redraw; a **fresh spawn** (first connect OR evicted-and-respawned) sends neither — client just starts receiving live output into what looks like a blank terminal. There is no explicit `{"type": "session.evicted"}` signal. The only inference available is client-side bookkeeping (have I connected to this `channelID` before + did this reconnect arrive with zero buffered bytes) — fragile, not authoritative. **Treat this as best-effort, not a guaranteed feature** (see §12).

---

## 3. Data model

```swift
@Observable
final class AppState {
    private(set) var sessions: [String: ProfileSession] = [:]  // key = profile id
    var activeProfileID: String?
    var backends: [BackendConfig] = []                          // future: multi-backend

    var activeSession: ProfileSession? {
        activeProfileID.flatMap { sessions[$0] }
    }

    var profilesNeedingAttention: Set<String> {
        Set(sessions.values.filter { $0.pendingApproval != nil }.map(\.profileID))
    }

    func addProfile(_ config: ProfileConfig) { sessions[config.id] = ProfileSession(config: config) }
    func removeProfile(_ id: String) { sessions[id]?.disconnect(); sessions.removeValue(forKey: id) }
    func selectProfile(_ id: String) { activeProfileID = id }  // never tears down other sessions

    // See §6 for refreshAll() / periodic refresh / pull-to-refresh
}

@Observable
final class ProfileSession: Identifiable {
    let id: String
    let profileID: String
    let config: ProfileConfig

    private(set) var messages: [Message] = []
    private(set) var status: SessionStatus = .idle
    private(set) var pendingApproval: ApprovalRequest?    // non-nil = HARD block on send()
    private(set) var pendingClarify: ClarifyRequest?       // soft — thread stays live
    private(set) var isConnected: Bool = false
    private(set) var sessionWasReset: Bool = false         // best-effort only, see §2.8 — never
                                                             // treat as authoritative

    // Three logical connections per session (may share transport internals,
    // but are semantically distinct — see §2):
    private var ptyTask: URLSessionWebSocketTask?     // §2.3 — raw bytes, chat + /image
    private var eventsTask: URLSessionWebSocketTask?  // §2.4 — structured events, drives orb
    private var rpcTask: URLSessionWebSocketTask?      // §2.5 — /api/ws JSON-RPC, approval/clarify

    private let auth: HermesAuthClient

    func connect() async throws { /* opens all three, each with its own freshly-minted ticket */ }
    func disconnect() { /* closes all three */ }

    func send(_ text: String) {
        guard pendingApproval == nil else { return }  // hard block enforced at model layer
        messages.append(Message(role: .user, text: text))
        // send over ptyTask
    }

    func sendImage(dataURL: String, filename: String) async throws {
        // POST /api/chat/image-upload, then ptyTask.send("/image \(path)")
    }

    func resolveApproval(choice: ApprovalChoice) {
        // send {"method":"approval.respond", ...} over rpcTask
        pendingApproval = nil
    }

    func resolveClarify(requestID: String, answer: String) {
        // send {"method":"clarify.respond", ...} over rpcTask — soft, does not touch pendingApproval
    }
}

enum SessionStatus { case idle, thinking, speaking, alert }

struct Message: Identifiable {
    let id: String
    let role: Role
    var text: String
    var kind: MessageKind = .plain
    enum Role { case user, agent }
}

enum MessageKind {
    case plain                                              // inline, plain monospace (§9)
    case fileAttachment(FileCard)
    case clarify(ClarifyRequest)
    case approvalResolved(choice: ApprovalChoice, summary: String)  // green receipt, stays in history
}

struct FileCard { let name: String; let sizeBytes: Int; let mimeType: String; let url: URL }

struct ApprovalRequest: Identifiable {
    let id: String              // request_id
    let sessionID: String
    let command: String         // redacted command string from server
    let choices: [ApprovalChoice]  // dynamic — render exactly what the server sent, 2-4 options
    let smartDenied: Bool
}
enum ApprovalChoice: String { case once, session, always, deny }

struct ClarifyRequest: Identifiable {
    let id: String               // request_id
    let prompt: String
    let detail: String?
    let options: [ClarifyOption]?  // nil = free-text answer expected instead of options
}
struct ClarifyOption: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let style: ClarifyOptionStyle
}
enum ClarifyOptionStyle { case neutral, affirmative, destructive }

struct ProfileConfig: Identifiable {
    let id: String            // e.g. "trading"
    let displayName: String
    let backend: BackendConfig
}

struct BackendConfig: Identifiable {
    let id: String
    let baseURL: URL
    var displayName: String
}
```

---

## 4. Auth client (unchanged from v1 — fully specced, implement as-is)

- `HermesAuthClient`: full RFC 8252 flow — PKCE generation, loopback redirect catcher (`Network.framework`, catches exactly one GET), token exchange, refresh with 60s expiry skew buffer, Keychain storage (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) for `refresh_token` only. Access token stays in-memory, never persisted to disk.
- Every connect (PTY, events, or RPC) mints its own fresh single-use ticket via `POST /api/auth/ws-ticket` immediately before dialing — tickets are interchangeable across endpoints (§2.7) but must never be reused across attempts.
- Concurrency model: **additive, not shared** — the same profile opened in Electron desktop and in Spectra consumes separate registry slots (different `channelID`s), not one shared session. No channel-sharing/mirroring in v1.

---

## 5. Onboarding flow

1. **Add backend** — `BackendConfigView`: text field for base URL. No manual channel-entry fallback needed (`/api/status` is public and real).
2. **Login** — OAuth via `ASWebAuthenticationSession` (in-app browser sheet that auto-dismisses back to the app on callback — no manual Safari→app switch). The RFC 8252 loopback catcher + PKCE flow (§4) is unchanged underneath; the loopback response just JS-bounces to `spectra://auth-done`, which the session's `callbackURLScheme` catches to close the sheet. Loading state: **orb spinning (`.connecting`) + "Setting up your workspace"**. On failure after retry: full error screen (app is unusable without a working backend connection — no silent infinite spinner, no degraded offline mode on first launch).
3. **Profile picker** — `GET /api/status` populates a checklist of discoverable profiles. **User selects which to add — not auto-add-all** (respects the 16-session cap; a backend with 8+ profiles shouldn't silently burn toward the ceiling). Include a **"Select all"** button for convenience.
4. On confirm: `AppState.addProfile()` for each selected profile, each auto-connects immediately (opens all three connection types — see §6).

---

## 6. Session lifecycle, refresh, and the 16-cap

- **Auto-connect on add, and on every app launch** for all previously-added profiles — this is what makes Profiles-tab badges and push notifications trustworthy at a glance. Removing a profile from the app must actually close its PTY (`disconnect()`), not just delete the local object — orphaned server-side sessions leak toward the cap.
- **Periodic refresh** (foreground only, ~30s interval) + **pull-to-refresh** + **on-foreground-transition** all call one shared `AppState.refreshAll()`: reconnects any session with `isConnected == false`. Re-syncs profile list from `/api/status` if new profiles appeared server-side (additive only — never removes a profile the user added, even if it disappears from discovery).
- iOS backgrounds/kills sockets ~30s after backgrounding — no way around this without a background daemon iOS doesn't allow third-party apps to run. Push notifications are what cover the user while backgrounded, not persistent background sockets.
- **16-cap is real, hardcoded server-side (`max_sessions=16` in `web_server.py`), not configurable via client.** Confirmed: **the cap is `/api/pty`-specific only** — `/api/events` and `/api/ws` do not draw from `PtySessionRegistry`. Each added profile therefore costs exactly **1 slot**, not 3, regardless of the three-socket architecture in §2. At current scale (a handful of profiles) this is a non-issue. Don't build cap-avoidance cleverness for v1. If ever hit, the fix is a server-side constant change on the user's own fork (MIT license), not a client workaround.
- **Scaling note (deferred, not a v1 concern):** if the 16-slot cap is ever genuinely hit (many profiles + Electron desktop open simultaneously), the fix is not to drop persistent PTYs across the board — it's to reserve `/api/pty` keep-alive for profiles with an active conversation worth resuming, and run added-but-idle profiles on `/api/ws`/`/api/events` only (no persistent PTY) until the user actually engages that profile's chat. Real tradeoff, deliberately out of scope at current 3-profile scale.

---

## 7. Orb (ThinkingOrbsKit)

- Package: `ThinkingOrbsKit` (SPM, MIT, iOS 15+/macOS 12+, no Metal — `Canvas` + `TimelineView(.animation)`).
- Nine states available: `breathing`, `searching`, `working`, `composing`, `connecting`, `shaping`, plus others per package docs. Map to `/api/events` (§2.4):

| State enum | ThinkingOrbsKit state | Trigger |
|---|---|---|
| `.idle` | `breathing` | No turn active |
| `.thinking` (search-type) | `searching` | `tool.start` for web_search/MCP query tools |
| `.thinking` (general) | `working` | `tool.start` for other tool calls |
| `.speaking` | `composing` | `delta` events streaming |
| — | `connecting` | Socket reconnect / ticket mint in progress |
| — | `shaping` | Small 20pt inline uses (per-message indicators) |

- **No built-in alert/danger state** — layer Spectra's own red badge/dot on top for `pendingApproval`/`pendingClarify`/error states rather than expecting the orb itself to convey it. `theme` only controls dark/light, not semantic color.
- Two sizes: `.px64` (Chat tab header) and `.px20` (inline per-message tool-call indicators).
- Respects `\.accessibilityReduceMotion` automatically. Auto-pauses off-screen via `TimelineView`.

---

## 8. Screens & navigation

4-tab bar: **Chat · Profiles · Tasks · Settings**.

### Chat
- Orb (`.px64`) persistent in header — dormant/`breathing` when idle, reflects active session's `status` otherwise.
- Message thread, newest at bottom, plain-monospace rendering for text/code (§9).
- Empty state: centered app mark, personalized greeting, one-line subtext, 2-per-row quick-start prompt chips. Tapping calls `send()` and transitions to normal thread view.
- Input bar pinned bottom: text field, attachment button (§2.6 flow), send button, active profile name shown in place of a model-picker.
- **Approval card** (hard block, §2.5): inline liquid-glass card. Renders **exactly the choices the server sent** — 2 to 4 buttons (once/session/always/deny), not a fixed pair. Swipe to collapse into a persistent chip above the input bar; tap to re-expand. On resolve: card shows the chosen option, turns green, **stays in the chat permanently as a receipt**.
- **Clarify card** (soft, §2.5): quieter row-list style if `options` present (title + subtitle per row), or a text-input prompt if `options` is nil. Ignorable — thread stays fully live. Selecting/answering sends via `clarify.respond` and collapses the card.

### Profiles
- List of added profiles: status dot (green = connected, gray = disconnected, client-derived only — no server-reported status exists), name, chevron to a **read-only, name-only** detail view (confirmed no richer metadata is fetchable, §2.2).
- Badge on tab bar icon + per-row when `pendingApproval` or `pendingClarify` is set for that profile.
- Empty state: centered icon, "No profiles added", "Add profile" button.
- **Explicitly out of scope for v1:** profile creation, SOUL.md editing, skill install/review, cron config, gateway/server rebind. Spectra is a cockpit, not a garage.

### Tasks
- Cross-profile live feed of tool-call/turn activity, newest first.
- Status vocabulary: **Pending, Failed, Success, In progress, In review, Expired, Submitted** — pill badges, one consistent color per status app-wide.
- Empty state: centered icon, "Nothing running."

### Settings
Flat, single-level sectioned list:
- **Backends** — list, add, remove, set default (multi-backend workspace switching deferred to future work)
- **Profiles** → per-profile Face ID toggle
- **Notifications** — on/off, rich-content toggle
- **Appearance** — System / Light / Dark
- **About** — version, GitHub link, MIT license text

---

## 9. Message rendering

- **Agent markdown is rendered** (past v1's plain-mono): headings, bullet/numbered lists, blockquotes, rules, and inline **bold**/*italic*/`code`/links (SwiftUI native inline). Fenced code blocks render monospaced on a surface card, horizontally scrollable, with a language label and a copy button. No syntax *highlighting* inside code blocks (still deferred). User messages stay plain.
- **Files: a card** — icon, name, size, open/share action.
- **Images: inline** — small thumbnail, tap to view full-screen (uses the §2.6 upload flow to send).

---

## 10. Local persistence / cache

- **Yes, cache locally.** Server's `attach=` resume gives buffered-tail replay but not instant cold-launch render. A lightweight local store (SwiftData or flat per-profile JSON/SQLite) renders the thread instantly from last-known messages, then reconciles with whatever the live reconnect brings.
- Read-through convenience only — server is always source of truth. Never let cache diverge into its own authoritative state.

---

## 11. Notifications

APNs push (token-based, ES256 `.p8`). Server half lives in Hermes; the client half is the entitlement + registration + delegate.

- **Transport** — Hermes signs an ES256 provider JWT with the `.p8` and POSTs over HTTP/2 to APNs. Per-token environment: dev/sandbox builds → `api.sandbox.push.apple.com`, Release/TestFlight → `api.push.apple.com`. The client reports its env at registration; the same `.p8` serves both. Dead tokens (410 / `BadDeviceToken`) are pruned on send.
- **Registration** — the client asks permission + `registerForRemoteNotifications` once it reaches the main app, then POSTs its device token to `POST /api/apns/register` (Bearer-auth). The token can race ahead of auth on a cached cold-launch, so it's re-flushed after `auth.restore()` and on foreground.
- **Trigger** — three events (v1.8.8), each hooked at its own gateway seam, all through the same `apns_sender.send_alert()`:
  - `approval.request` (the time-sensitive, actionable case) — body carries the profile name + redacted command, truncated to 180 chars.
  - `message.complete` (reply-completion, "Finish") — fires only when `status == "complete"` (not error/interrupted); body is a ~100-char plain-text snippet of the reply with markdown/code stripped.
  - `clarify.request` (the agent's soft, non-blocking question) — body carries the actual question text (first question, for a batch clarify), truncated to 180 chars.
- **Foreground suppression** — the client drops the banner when the pushed profile is already on screen (`willPresent`), so it only surfaces when not foregrounded for that profile.
- **Rich content** — iOS handles lock-screen visibility per user preference; approval summaries appear directly in the notification.
- Interactive inline actions (Approve/Deny from the notification) remain a stretch goal, not a v1 blocker.
- Server config lives outside the repo in `~/.hermes/apns/` (the `.p8`, `config.json` with team id + topic, `tokens.json` token store).

---

## 12. Error / offline states

- **Backend unreachable:** orb shows `.connecting` while auto-retrying; explicit error screen after retries exhaust — no infinite spinner.
- **Auth expired (`401 session_expired`):** force back to login for that backend, don't silently fail sends.
- **Ws-ticket mint failure:** same retry/error path as backend-unreachable.
- **Suspected session eviction:** per §2.8, this is best-effort only. If your client-side heuristic (never-connected-before + zero buffered bytes) fires, surface a soft, non-alarming note ("thread may be missing recent history") — do not present this as a confirmed event, since the wire signal isn't authoritative.

---

## 13. Accessibility

- VoiceOver labels on all orb states (ThinkingOrbsKit ships this per-state natively).
- Dynamic Type support on all text — system text styles only.
- Approval/clarify card colors must pass WCAG contrast.
- Respect `\.accessibilityReduceMotion` everywhere motion appears — don't override the package's handling.

---

## 14. Branding

- App mark: four-petal pinwheel/compass logo (attached SVG), solid shapes, reads well small.
- App icon: needs an opaque background baked in (dark/near-black recommended). Export at 1024×1024.
- Consider (not required v1): tying the static icon mark to the orb's `breathing` resting shape as a visual through-line.

---

## 15. Explicitly deferred / out of scope for v1

- Multi-backend workspace management
- Syntax highlighting in code blocks
- Profile creation, SOUL.md editing, skill review/install, cron config
- Server-side ticket scope enforcement (currently unscoped by design of the server, §2.7 — not a client-side fix)
- Channel-sharing/session-mirroring between Electron desktop and Spectra
- Live Activities / Dynamic Island, App Intents/Siri, Handoff, Lock Screen widgets
- Raising the server's `max_sessions=16` constant
- Reliable session-eviction detection (confirmed not available on the wire today, §2.8)
- Server-side exposure of `ProfileInfo` metadata for a richer Profiles detail view (confirmed absent today, §2.2)

---

## 16. Genuinely open items

None. All items previously flagged as unverified have been traced against actual server source and answered with confirmed behavior (§2.3 keepalive, §2.6 attachments, §2.2 metadata, §2.8 eviction, §2.7 ticket scope, §2.5 approval/clarify). Nothing in this spec is a guess.
