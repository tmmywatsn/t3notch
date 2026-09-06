# Internals

Notes on how this talks to T3 Code, what the alternatives cost, and where the edges are. Measured
against T3 Code 0.0.38.

## Transport

The app tails T3 Code's own on-disk state:

1. `stat()` on `~/.t3/userdata/state.sqlite` and its `-wal` four times a second. They only change
   when T3 Code commits something, so this is nearly free.
2. On a change, read-only SQLite queries against `projection_threads`, `projection_thread_sessions`,
   `projection_turns`, `projection_thread_activities`, `projection_pending_approvals` and
   `projection_projects`, plus session boundaries in `orchestration_events`.
3. A run finishes after its session, turn and background tasks have stopped working for three
   seconds. The same grace period keeps its working row visible during subagent handoffs.

The connection is opened `mode=ro` with `SQLITE_OPEN_READONLY`, on a background queue.

### Why not the HTTP API

There is a real one. `npx -y t3@latest auth session issue --token-only` mints a bearer token valid
for 30 days with `orchestration:read` and `orchestration:operate`, and
`GET /api/orchestration/shell` returns an 11 KB snapshot of every thread with a `snapshotSequence`
to detect no-op polls.

The problem is the detail the open panel needs — the command in flight, the context window. That
lives in `GET /api/orchestration/threads/:id`, which is **240 KB for one active thread** because it
carries the whole message and activity history. You would fetch it only for threads you are looking
at, and hovering would cost a round trip.

### Why not the WebSocket

`GET /ws` authenticates with `?wsTicket=<ticket>` from `POST /api/auth/websocket-ticket` and offers
`orchestration.subscribeShell` and `orchestration.subscribeThread` — real push. It speaks Effect's
*unstable* RPC protocol rather than plain JSON; a JSON request over the socket is ignored.
Implementing that in Swift means tracking a beta protocol.

### What the API would unlock

Writes. `POST /api/orchestration/dispatch` accepts, among others,
`thread.approval-response-requested`, `thread.user-input-response-requested`,
`thread.turn-interrupt-requested`, `thread.snooze` and `thread.settle` — so answering a question or
approving a tool call from the notch is possible, and reading state over SQLite doesn't preclude it.

## Thread status

The dot colours follow `resolveThreadAwarenessPhase` in T3 Code's server, precedence included, so a
thread reads here the way T3 Code classifies it for its own remote notifications:

`waiting_for_approval` → `waiting_for_input` → `failed` → `starting` → `running` → `completed` →
`stale`

Everything available per thread:

| Signal | Values |
| --- | --- |
| `session.status` | `idle`, `starting`, `running`, `ready`, `interrupted`, `stopped`, `error` |
| `latestTurn.state` | `pending`, `running`, `interrupted`, `completed`, `error` |
| `backgroundLiveness` | `working`, `monitoring`, `null` — subagents or watch loops alive *after* the turn settles |
| `planProgress` | `{ step, completedSteps, totalSteps }`, cleared when the turn settles |
| `hasPendingApprovals` | a tool call is waiting for your yes |
| `hasPendingUserInput` | the agent asked you a question |
| `hasActionableProposedPlan` | a plan is waiting for your review |
| `settledOverride` | `settled` or `active` — T3 Code's own "wants your eyes" flag |
| `snoozedUntil` | quiet until a time |
| `pinnedAt`, `pinOrderKey` | pinned threads, in your order |
| `archivedAt`, `deletedAt` | lifecycle |
| `interactionMode` | `default` or `plan` |
| `linkedPullRequest` | `{ repository, number, url }` |
| activity `tone` | `info`, `tool`, `approval`, `error` |
| activity `kind` | `tool.*`, `task.*`, `context-window.updated`, `checkpoint.*`, `user-input.*`, `turn.plan.updated`, `runtime.error`/`warning` |
| context window | `usedTokens` / `maxTokens` |
| checkpoints | per-turn changed files with `additions` / `deletions` |

`backgroundLiveness` and `planProgress` are computed by the server and appear only on the HTTP API,
not in the SQLite projections. The notch reconstructs background work from persisted `task.started`,
`task.updated`, `task.progress` and `task.completed` activities. It reads the lifecycle before
ranking threads and separately from the 40-entry UI feed, so a child remains visible across turns
and long tool histories. Idle, cancelled and finished tasks stop counting; status-less progress
cannot revive them. Plan/dream bookkeeping and nested monitor activity follow T3 Code's exclusions.

Session stop events provide a cutoff for discarding orphaned tasks. A recoverable main-turn failure
does not clear surviving children; their lifecycle is still available after a retry. This remains
an inference from persisted events: missing lifecycle events cannot be recovered from the server's
in-memory registry without using its API. The three-second handoff grace bridges brief gaps between
session and task writes. The store's one-second timer resolves the grace even if no more database
writes arrive; failures and interruptions bypass it.

## Opening a specific thread

Not possible against the desktop app today.

- `t3code://` and `t3code-dev://` are registered as the Electron renderer's *origin*, not as inbound
  deep links. `main.cjs` has no `open-url` or `will-finish-launching` handler, and its
  `second-instance` handler reveals the window and ignores argv.
- The web client does have the route, `/$environmentId/$threadId`, and T3 Code's relay builds
  `/threads/<environmentId>/<threadId>` links for remote notifications. Requesting that path on the
  local server redirects to `/pair`: a desktop-managed environment refuses a browser session without
  an explicitly issued bootstrap credential.

Pairing a browser once would make `http://127.0.0.1:3773/<environmentId>/<threadId>` open the exact
thread, but in a browser tab rather than the desktop app. An inbound `open-url` handler upstream
would make it work properly; the route and link format already exist there.

## Window behaviour

The panel is an `NSPanel` above the menu bar, on every Space. Two things are worth knowing:

- **Hover is polled from the cursor**, not `onHover`. Expanding swaps the SwiftUI subtree, which
  re-fires `onHover` and sends the panel into a collapse/expand loop.
- **Collapsed, the panel sets `ignoresMouseEvents`.** It claims 62pt of menu bar either side of the
  cutout and must not swallow clicks there. Only the cutout, plus 18pt either side, opens it.
- The exit region is sticky: it follows the panel down only once the cursor is back inside, so a
  panel that shrinks under a stationary cursor doesn't close itself.

`NSHostingView.sizingOptions` is set to `[]`. Left alone it constrains the window to the SwiftUI
content's ideal size, which fights the frames the controller sets.

## Releases and updating

`VERSION` at the repo root is the single source of truth. `build-app.sh` reads it, so a source
tarball with no git history still stamps the bundle correctly, and `release.yml` refuses to publish
a tag that disagrees with it. A build that is not sitting exactly on its release tag, or that has a
dirty tree, gets a `1.0.0+abc1234` build identifier in `T3NotchBuild` — display only, since
`CFBundleShortVersionString` has to stay a plain dotted number.

### Why releases carry no binary

Gatekeeper. `build-app.sh` signs ad-hoc, which is enough to run locally but not enough to survive a
download: the quarantine attribute on a fetched `.app` with no Developer ID gets it reported as
damaged, and the workaround is teaching every user `xattr -dr com.apple.quarantine`, which is a bad
habit to hand out. So a release is a tag plus notes, and updating means rebuilding from it.

Changing that needs an Apple Developer Program membership: sign with a Developer ID Application
certificate, `notarytool submit --wait`, then `stapler staple`. With notarised builds the natural
next step is [Sparkle](https://sparkle-project.org) and a signed appcast, at which point the check
in `UpdateCheck.swift` would be replaced rather than extended. Nothing here is designed to prevent
that; the version comparison stays useful either way.

### The update check

One unauthenticated `GET` to `/repos/tmmywatsn/t3notch/releases/latest`, at most once a day, gated
on `Settings.checkForUpdates`. The timer ticks hourly and the interval is enforced against a
timestamp in `UserDefaults`, so a Mac asleep through its slot checks shortly after waking rather
than skipping a day. `/releases/latest` already excludes drafts and pre-releases; the flags are
honoured anyway in case that changes. Parsing is split into a `nonisolated static` function purely
so the tests can drive it without a network.

Unauthenticated GitHub API calls are limited to 60 an hour per IP address. One a day per user is
nowhere near it, and a 403 is treated the same as any other non-200: no update, try tomorrow.

## Known limitations

- The project builds in Swift 5 language mode. `T3Reader` is a plain class handed between the main
  actor and its own queue, and the value types it returns are not marked `Sendable`, so adopting
  Swift 6 strict concurrency will need work.
- `Tests/main.swift` (run with `Scripts/test.sh`) covers pure logic and the SQLite → reader → store
  handoff path using a temporary fixture database and a controlled clock. The UI is exercised by
  hand through `Scripts/fixture.sh`.

## Toolchain

There is no `Package.swift`. `Scripts/build-app.sh` calls `swiftc` directly, because Command Line
Tools 16.4 ships a `PackageDescription.swiftinterface` whose `Package.init` mangles
`swiftLanguageVersions` as `[SwiftVersion]` while its `libPackageDescription.dylib` exports only
`[SwiftLanguageMode]`. The interface and the binary disagree as shipped, so `swift build` fails
before reaching any project code. Installing Xcode or a swift.org toolchain fixes it; nothing here
needs SwiftPM.

Separately, some installs leave a 2023-era `module.modulemap` beside `bridging.modulemap`, both
defining `SwiftBridging`, which breaks every AppKit import. The build script masks it with a virtual
filesystem overlay; `sudo ./Scripts/fix-toolchain.sh` moves the stale file aside for good.

## Layout

```
Tests/main.swift        Logic and SQLite/store regression tests, run by Scripts/test.sh
Sources/T3Notch/
  main.swift            Entry point; accessory app, no Dock icon
  AppDelegate.swift     Wiring and the menu bar item
  Debug.swift           Stderr diagnostics behind T3NOTCH_DEBUG
  Notifier.swift        Store events -> banner, sound, Notification Centre; Settings
  UpdateCheck.swift     Version comparison and the daily release check
  Model/
    SQLite.swift        Minimal read-only sqlite3 wrapper
    T3Database.swift    Queries against T3 Code's projections
    T3Reader.swift      Background queue owning the connection
    T3Store.swift       WAL watching, run/finish detection, published state
    Models.swift        AgentRun, ThreadPhase, ActivityLine, ContextWindow
    BackgroundTasks.swift Task lifecycle folding for work that outlives a turn
  UI/
    NotchGeometry.swift Finds the cutout, or fakes one
    NotchShape.swift    Panel outline, flaring into the menu bar
    NotchPanel.swift    Panel window, hover polling, sizing
    NotchViews.swift    Root view, collapsed clusters, banner
    ExpandedPanel.swift Hover panel and settings
    ProviderStyle.swift Accent colours read from T3 Code's settings
```
