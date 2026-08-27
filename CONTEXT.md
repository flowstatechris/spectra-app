# Spectra

Native iOS/macOS client for a self-hosted Hermes Agent instance. Spectra owns no agent logic — it's a cockpit that renders and drives the state a Backend already has.

## Language

**Backend**:
One running `hermes_cli.main serve` process, identified by its base URL. Everything Spectra talks to is scoped to a single Backend.
_Avoid_: Server, gateway, instance (the wire docs use "gateway" for the same thing — in Spectra's own code, say Backend)

**Profile**:
A named agent configuration that lives on a Backend (e.g. `trading`, `odrop`). The unit the user adds, removes, and connects to independently of other profiles on the same Backend.
_Avoid_: Agent, bot

**ProfileSession**:
The client-side object holding one Profile's live chat state: its message history, status, pending Approval/Clarify, and its server Session id. One per added Profile. All wire traffic flows through the Backend's shared RPC connection (see ADR-0002).
_Avoid_: Connection, socket (a ProfileSession doesn't own a socket — the Backend's RPC connection is shared)

**RPC connection**:
The single JSON-RPC WebSocket (`/api/ws`) per Backend carrying everything: chat (`session.create`/`prompt.submit`), streaming events (`message.delta`, `status.update`, `tool.start`/`tool.complete`), Approval and Clarify requests/responses, and rich profile metadata (`profiles.list`). Line-delimited JSON-RPC 2.0; events are `method: "event"` notifications with `params.type`/`params.session_id`/`params.payload`.
_Avoid_: WS (bare), gateway socket

**Session** *(server-side)*:
One conversation thread the Backend owns, created via `session.create` (scoped to a Profile), addressed by `session_id`, with durable history readable via `session.history`. Outlives any socket.
_Avoid_: Chat, thread (in code — UI copy may say "chat")

**Approval**:
A hard block on sending: the server requires the user pick one of 2-4 dynamic choices (`once`/`session`/`always`/`deny`) before the ProfileSession will accept new input. Delivered and resolved over the RPC connection. Once resolved, becomes a permanent green receipt in the message history.
_Avoid_: Permission request, confirmation

**Clarify**:
A soft prompt from the agent: rendered inline, ignorable, does not block `send()`. Same RPC connection as Approval, but a separate request/response pair (`clarify.request`/`clarify.respond`). The same mechanism the agent itself uses to ask the user things mid-turn.
_Avoid_: Question, prompt (bare)

**Orb**:
The persistent status indicator (ThinkingOrbsKit) reflecting a ProfileSession's `SessionStatus` — the one place Spectra shows "what is this agent doing right now" without reading chat text.
_Avoid_: Spinner, loader, indicator (bare)

**Dashboard auth provider** *(Backend-side concept, not Spectra's to implement — noted here because it shapes what the login screen can assume)*:
The Backend registers exactly one interactive session provider for native sign-in: either an OAuth provider (redirects to an upstream IDP) or a password provider like the bundled `basic` plugin (redirects the system browser to the Backend's own `/login` form instead). Spectra's login flow is identical either way — open `/auth/native/authorize` with `provider` left blank (auto-selects the sole registered provider) and wait for the loopback redirect. Spectra never needs to know or care which kind is configured.
_Avoid_: OAuth provider (not always true — sometimes it's a password form)
