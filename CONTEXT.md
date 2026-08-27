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
The client-side object holding one Profile's live connection state: its message history, status, pending Approval/Clarify, and its three independent sockets (PTY, Events, RPC — see below). One per added Profile.
_Avoid_: Connection, session (bare) — always qualify: "the PTY connection," "the events connection," not "the socket"

**PTY connection**:
The raw terminal-byte-stream socket (`/api/pty`) carrying chat text in and rendered output back. `/image` and other slash commands are sent here as plain text, not JSON. Supports `attach=<channelID>` resume: detaching buffers into a 30-minute ring buffer rather than killing the session.
_Avoid_: Chat socket, terminal socket

**Events connection**:
The structured JSON status stream (`/api/events`). Passive — only emits while a PTY session on the same channel is live and running. Drives the Orb; carries no approval/clarify data.
_Avoid_: Status socket

**RPC connection**:
The JSON-RPC socket (`/api/ws`) carrying Approval and Clarify requests/responses. Distinct from both PTY and Events — a third, separate connection per ProfileSession.
_Avoid_: WS, the websocket (there are three; always name which)

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
