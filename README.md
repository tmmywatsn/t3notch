<div align="center">

# T3 Notch

**Your [T3 Code](https://github.com/pingdotgg/t3code) agents, in the notch.**

[![CI](https://github.com/tmmywatsn/t3notch/actions/workflows/ci.yml/badge.svg)](https://github.com/tmmywatsn/t3notch/actions/workflows/ci.yml)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-1d1d1f?logo=apple&logoColor=white)](#install)
[![Swift](https://img.shields.io/badge/Swift-AppKit%20%2B%20SwiftUI-F05138?logo=swift&logoColor=white)](#how-it-works)
[![MIT](https://img.shields.io/badge/licence-MIT-blue)](LICENSE)

</div>

It stays invisible until an agent is doing something, shows what's running at a glance, and drops a
banner when a run finishes. No token, no pairing, no `t3` CLI — it reads the state T3 Code already
writes to disk.

<div align="center">
  <img src="docs/panel.png" alt="The open panel" width="620">
</div>

## What it shows

Point at the notch and it opens: **anything waiting on you first**, then each running agent with its
project, branch, model, elapsed time, the command in flight, plan progress and context usage. Then
recent completions, held until you've looked at them or half an hour passes.

Collapsed, it's two clusters either side of the cutout. Nothing animates.

<div align="center">
  <img src="docs/collapsed.png" alt="The collapsed indicator" width="420">
</div>

**Left — one dot per live thread:**

| Colour | Meaning |
| --- | --- |
| Amber | Wants your input, approval, or a plan reviewed |
| Red | Failed |
| Provider colour | Working |
| Dimmed | Starting up |

**Right — a count**, taking the first that applies: amber if any thread wants you, a green ✓ (red ✗
on failure) if nothing is live but a finish is unread, otherwise white for the number working. A
ring appears once a working thread passes 80% of its context window, turning red past 92%.

Newest sits closest to the cutout; older threads trail away from it and wrap onto a second row. The
sort key is when the run started, so nothing reshuffles while an agent works.

<div align="center">
  <img src="docs/banner.png" alt="The completion banner" width="520">
</div>

## Install

Requires **macOS 14+**, T3 Code, and the Xcode Command Line Tools.

```sh
git clone https://github.com/tmmywatsn/t3notch.git
cd t3notch
./Scripts/build-app.sh
cp -R "build/T3 Notch.app" /Applications/
open "/Applications/T3 Notch.app"
```

Launch it from `/Applications` rather than `build/`, which is rebuilt in place. To start it
automatically, add it under **System Settings → General → Login Items → Open at Login**.

On a Mac without a physical notch it uses a 190pt region in the middle of the menu bar instead;
everything else behaves the same.

> [!NOTE]
> [Releases](https://github.com/tmmywatsn/t3notch/releases) are source-only. Builds are ad-hoc
> signed, so a downloadable `.app` would arrive quarantined and need its attributes stripped by
> hand — worse advice than a rebuild.

## Updating

From your clone:

```sh
./Scripts/update.sh
```

It pulls, runs the tests, rebuilds, then quits and replaces the copy in `/Applications`, relaunching
it if it was running. It stops without touching anything if you have uncommitted changes or the
branch has diverged.

The app checks once a day whether a newer version is tagged and puts a dot on the settings cog when
there is one. Turn it off under **Check for updates**; see [Privacy](#privacy) for exactly what that
request contains.

## Settings

The cog at the bottom right of the open panel.

<div align="center">
  <img src="docs/settings.png" alt="Settings" width="560">
</div>

| Setting | Default | Controls |
| --- | --- | --- |
| Banner in the notch | On | The drop-down summary when a run finishes |
| Play a sound | On | A chime on finish, a thud on failure, a ping when you're asked something |
| Announce short runs | Off | Whether turns under three seconds count as a run |
| Check for updates | On | A daily look at the releases page — the app's only network access |

Two more — Notification Centre banners and Start at login — appear only on a build signed with a
Developer ID, since macOS refuses both to ad-hoc signed apps.

## How it works

T3 Code's HTTP API needs a paired credential, so instead of polling it the app tails the state T3
Code already writes to disk: a `stat()` on the SQLite database and its WAL four times a second, then
read-only queries against the projection tables when something has changed.

> [!IMPORTANT]
> Those tables are T3 Code's private storage, not a published API, so an upstream change could
> rename them. Every query is defensive — a missing table shows "Waiting for T3 Code" rather than
> crashing — and they all live in [`T3Database.swift`](Sources/T3Notch/Model/T3Database.swift).

[`docs/internals.md`](docs/internals.md) covers the alternatives that were measured and rejected,
the thread status vocabulary, and why clicking through to a specific thread isn't possible yet.

## Privacy

- Reads `~/.t3/userdata/state.sqlite` **read-only**, `stat()`s the WAL beside it, and reads
  `settings.json` for your provider accent colours. Nothing else — never `clerk-tokens.json` or
  `secrets/`.
- Writes five booleans and the last update-check time to `UserDefaults`, and keeps no other state.
- **Makes exactly one kind of request, and only with Check for updates on:** an unauthenticated
  `GET` to `api.github.com/repos/tmmywatsn/t3notch/releases/latest`, at most once a day. It carries
  no identifier beyond `T3Notch/<version>` in the `User-Agent`, uses an ephemeral session so nothing
  is cached to disk, and reads only the tag name. Switch the setting off and no request is ever
  made.
- **No telemetry, no analytics, no crash reporting.** Nothing about you or your threads leaves the
  machine, ever. The only dependencies are Apple frameworks and `libsqlite3`; it is one file,
  [`UpdateCheck.swift`](Sources/T3Notch/UpdateCheck.swift), and roughly 40 lines of it.

## Development

```sh
./Scripts/test.sh        # pure-logic assertions
./Scripts/build-app.sh   # builds build/T3 Notch.app
```

`Scripts/fixture.sh` builds a throwaway database so you can drive every state without T3 Code
running:

```sh
./Scripts/fixture.sh setup && ./Scripts/fixture.sh seed
T3NOTCH_USERDATA=/tmp/t3notch-fixture "build/T3 Notch.app/Contents/MacOS/T3Notch" &
./Scripts/fixture.sh run      # working
./Scripts/fixture.sh ask      # a question
./Scripts/fixture.sh finish   # completion banner
./Scripts/fixture.sh fail     # failure banner
```

`T3NOTCH_DEBUG=1` logs frame and event decisions to stderr. `T3NOTCH_PREVIEW=1` fires a sample
banner at launch.

Some Command Line Tools installs ship a stale `module.modulemap` that breaks any AppKit import. The
build script works around it; `sudo ./Scripts/fix-toolchain.sh` removes it properly.

## Contributing

Issues and pull requests welcome.

`main` is protected: CI must be green on both macOS 14 and latest before a pull request can merge,
and history stays linear. Add an assertion to `Tests/main.swift` for anything with logic in it.

Releases are cut from the `VERSION` file, which is the single source of truth for the version the
app reports. Bump it in a pull request, then tag the merge commit:

```sh
git tag v1.1.0 && git push origin v1.1.0
```

`release.yml` refuses to publish if the tag and `VERSION` disagree, then builds, tests and writes
the notes from the commits since the previous tag.

## Licence

[MIT](LICENSE). Not affiliated with, endorsed by, or sponsored by T3 or T3 Code.
