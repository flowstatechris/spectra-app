# Spectra UX Handoff

Updated: August 27, 2026

## Where the product is now

Spectra's Chat surface has moved from a basic message view to a useful native
control surface for Hermes. The six planned vertical slices are implemented in
the current working tree:

1. Structured tool activity rows
2. Collapsing Chat header
3. Approval cards
4. Clarification cards and error states
5. Improved composer and Stop control
6. Activity-to-Chat deep linking

This work is intentionally incremental. It extends the existing
`AppState`/`ProfileSession` architecture and shared JSON-RPC connection rather
than replacing the app or introducing another navigation/state framework.

## Completed work

### Structured Chat timeline

- `tool.start`, `tool.started`, `tool.complete`, and `tool.output_risk` now fold
  into one durable `ToolActivity` message at the correct chronological position.
- Rows use human-readable descriptions, quiet collapsed presentation, and
  expandable details for input, output, duration, exit code, risk, and findings.
- Running, successful, and failed tool calls update the same row instead of
  appending disconnected status messages.
- Tool activity is Codable and survives the existing lightweight thread cache.

### Collapsing header

- Chat opens with the existing expanded profile/orb/status presentation.
- Scrolling into the conversation collapses it to a persistent compact header.
- Significant session-status transitions temporarily restore the expanded state.
- Orb status copy is centralized in `OrbView` so compact and expanded headers use
  the same state mapping.

### Sign-in appearance

- The onboarding/sign-in background now fills the entire screen consistently.
- This fixes the mismatched vertical bands visible behind the system sign-in
  confirmation sheet.

### Approvals

- `approval.request` is a first-class timeline event, not a floating overlay.
- Only the choices supplied by Hermes are rendered.
- An unresolved Approval blocks normal sending in `ProfileSession`, not only in
  the view.
- The card can collapse into a persistent “Hermes needs permission” chip above
  the composer.
- Resolution leaves a timestamped granted or denied receipt in conversation
  history.
- Stale requests that resolve zero server-side approvals become expired instead
  of pretending to succeed.
- RPC failures remain visible and leave the active card retryable.

### Clarifications and errors

- `clarify.request` is an inline, non-blocking conversation object.
- Choice, free-text, batch, seeded reconnect answers, and multi-select forms are
  supported.
- Partial batch answers remain visible while unanswered questions stay active.
- Completed clarifications collapse into timestamped answer receipts.
- Hermes's late-response `{status: "expired"}` result is handled explicitly.
- Expired clarifications, turn errors, and response failures remain visible in
  the timeline.
- A `turn.error` also marks the current running tool as failed.

### Streaming freeze mitigation

The likely simulator freeze was in Spectra's render path, not Hermes:

- Every streaming token was reparsing the entire growing Markdown response.
- Every token also started another animated 0.2-second scroll.
- Hermes Desktop showing a normal trace and response supported this diagnosis.

During streaming, the active response now renders as lightweight plain text.
Markdown is parsed once when the response completes, and token updates no longer
queue overlapping scroll animations. If a freeze remains, the next measurement
should focus on batching `message.delta` observation updates rather than changing
the Hermes transport.

### Composer

- The field grows from one through six lines, then scrolls internally.
- The attachment affordance is now a native `+` menu with Photo Library, Camera,
  and File actions.
- Camera usage has the required Info.plist privacy description.
- Non-image files use Hermes `file.attach`, retain the returned rewritten
  `@file:` reference, and prepend it only to the submitted wire prompt.
- The visible user message shows the filename and size without exposing the
  internal Hermes reference.
- Image and file previews appear above the composer and in sent messages.
- While Hermes is generating or executing, the send button becomes a red Stop
  control backed by `session.interrupt`.
- Approval-blocked copy remains explicit: “Resolve permission request above.”

The composer deliberately retains the existing one-pending-attachment model.
Selecting another attachment replaces the current one.

### Activity

- The user-facing Tasks tab is renamed Activity.
- Status copy is now Working, Waiting, Success, Failed, or Interrupted.
- Each `ActivityItem` stores the timeline message ID it represents.
- Tapping a row selects its Profile, opens Chat, and scrolls to the corresponding
  tool, Approval, Clarify, or error event.
- The implementation uses native `TabView(selection:)` and `ScrollViewReader`;
  there is no separate router.

## Important implementation locations

- `SpectraCore/Sources/SpectraCore/Models.swift`
  - Timeline message kinds, tool/Approval/Clarify/error events, attachment model.
- `SpectraCore/Sources/SpectraCore/ProfileSession.swift`
  - Send/interrupt behavior and all session-event folding.
- `SpectraCore/Sources/SpectraCore/AppState.swift`
  - Cross-profile Activity folding, attachment staging, and Chat destinations.
- `SpectraCore/Sources/SpectraCore/ActivityItem.swift`
  - Activity status and target message ID.
- `spectra-app/Views/ChatView.swift`
  - Header, timeline rows/cards, composer, attachment pickers, and deep-link scroll.
- `spectra-app/ContentView.swift`
  - Selected tab and Activity-to-Chat transition.
- `spectra-app/Views/TasksView.swift`
  - The user-facing Activity feed. The filename is legacy; the view is
    `ActivityView`.

## Verification status

- `swift test`: 34 tests pass, including live auth/RPC/attachment integration.
- `xcodebuild ... build`: passes for the iPhone 17 simulator.
- The built app installs and launches successfully in the booted simulator.
- `git diff --check`: clean.
- Camera privacy text is present in the built app's Info.plist.

The updated Activity UI test compiles, but its login helper is stale. It still
expects authentication to move into the standalone Mobile Safari application.
The current sign-in flow stays inside Spectra's presented authentication UI, so
XCTest fails with `application com.apple.mobilesafari is not running` before any
Activity assertion executes. This is a test-harness failure, not an observed
product failure.

Existing unrelated warnings:

- `HermesRPCConnection.Event` stores `[String: Any]?` while conforming to
  `Sendable` (future Swift 6 issue).
- `AuthPresenter` retains the deprecated iOS 26 fallback
  `ASPresentationAnchor()` initializer.

## Suggested next steps

### 1. Update UI-test authentication first

Rewrite the shared UI-test login helper to interact with the authentication UI
presented by Spectra rather than `XCUIApplication(bundleIdentifier:
"com.apple.mobilesafari")`. Then rerun the Activity deep-link test and add a
small composer test covering multiline growth and Stop.

### 2. Bring Hermes chat sessions into Spectra

This is the strongest candidate for the next major product slice. Spectra
currently presents one continuous Chat per Profile, while Hermes already owns a
durable session system with recent-session listing, titles, previews, history,
resume, branch, close, and delete operations.

It also fixes an important continuity gap: `session.create` returns both an
ephemeral runtime `session_id` and a durable `stored_session_id`, but Spectra
currently retains only the runtime ID. After a reconnect, the next send creates
a new server session instead of resuming the conversation Hermes already has.

Start with a mobile-sized Session switcher slice:

- Capture and persist `stored_session_id` separately from the live runtime ID.
- Tap the Chat title/header to open recent sessions for the active Profile.
- Populate title, preview, date, and message count from profile-scoped
  `session.list`.
- Add a clear New Chat action.
- Selecting a session calls `session.resume`, adopts its new runtime ID, and
  restores its messages.
- On reconnect, resume the selected durable session rather than silently
  creating a new conversation.
- Initially disable session switching while a turn or Approval is active. This
  avoids introducing multiple simultaneously supervised runtimes in the first
  slice.

Do not copy Hermes Desktop's entire session-management surface into the first
version. Rename, branch, archive/delete, search, pins, and multiple concurrently
running chats can follow once basic list/new/resume behavior is solid.

The main data-model risk is historical timeline fidelity. Hermes provides the
underlying conversation history, while Spectra also owns custom ToolActivity,
Approval, Clarify, and error presentation objects. The local timeline cache
should therefore become keyed by durable session ID and reconcile with Hermes
history instead of being discarded whenever a session is resumed.

### 3. Exercise the new composer on a physical device

The simulator cannot validate the camera. On-device checks should cover:

- Camera authorization, capture, preview, removal, and send.
- Photo Library and Files cancellation paths.
- A remote `file.attach` followed by a prompt that actually reads the file.
- Large-file RPC errors and slow-upload feedback.

### 4. Decide whether multi-attachment composition is worth the model change

Today there is one pending attachment, matching the pre-existing architecture.
If real usage needs several files in one turn, change `pendingAttachment` to an
array and stage/remove each item independently. Avoid doing this speculatively;
it touches persistence, prompt construction, retry behavior, and layout.

### 5. Improve Activity continuity

The live feed is currently memory-only and primarily tool-backed. Useful future
increments would be:

- Persist a bounded Activity snapshot across launch.
- Represent turn-level interruptions even when no tool is running.
- Briefly highlight the destination row after a deep link.
- Add explicit Approval/Clarify Activity rows when no preceding tool row exists.

### 6. Finish the attention system

Profiles already expose a badge when a Profile has a pending Approval or
Clarify. Next, align Activity, notification routing, and profile-row copy around
the same attention vocabulary without treating routine work as an alert.

### 7. Profile only if freezes recur

The two obvious per-token hot paths are removed. If a long response still
freezes the simulator, capture a Time Profiler trace before adding buffering.
The smallest likely follow-up is coalescing `message.delta` mutations to one UI
update per display frame.

## Working-tree note

All progress described here is currently in the working tree and has not been
committed as part of this handoff. Preserve the existing modified and untracked
files when continuing.
