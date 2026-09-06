# Contributing to T3 Notch

Bug reports, documentation improvements and focused pull requests are welcome. Please follow the
[code of conduct](CODE_OF_CONDUCT.md). T3 Notch is an independent project; problems in T3 Code itself
belong in [its repository](https://github.com/pingdotgg/t3code).

## Getting started

You need macOS 14 or newer and the Xcode Command Line Tools (`xcode-select --install`). Clone the
repository, create a branch, and run:

```sh
./Scripts/test.sh
./Scripts/build-app.sh
open "build/T3 Notch.app"
```

Quit that development copy before rebuilding it. The scripts invoke `swiftc` directly; there is no
SwiftPM package and no third-party runtime dependency. See [internals](docs/internals.md) for the
layout, toolchain workaround and known limitations.

## Reporting a problem

Search [existing issues](https://github.com/tmmywatsn/t3notch/issues) first. Include the notch version
or commit, T3 Code version, macOS version, expected behavior and the smallest reproduction you can
find. A screenshot is useful for layout problems. Remove chat contents, project paths, credentials
and other private data from screenshots and logs. Never upload your T3 Code database.

Use [private vulnerability reporting](SECURITY.md) for security issues.

## Making a change

- Keep a pull request focused on one problem. Discuss substantial interface or architecture
  changes in an issue before investing in an implementation.
- Follow the surrounding Swift style: four-space indentation, descriptive names and small types
  with a clear responsibility. Explain non-obvious invariants and upstream assumptions in comments.
- Keep T3 Code database access read-only and off the main thread. Put queries in `T3Database` and
  model work in `Model/`; keep view code concerned with presentation.
- Preserve the privacy guarantees in the README. Describe any proposed data access, persistence
  or network change explicitly in the pull request.
- Add a regression test for a bug or a meaningful assertion for new behavior. Use a temporary
  fixture and controlled timestamps for database and timing tests; tests must not depend on a
  contributor's real chats, settings or running T3 Code session.
- Update user or developer documentation when behavior or the setup process changes. Do not
  include generated apps, private logs or local databases in commits.

Before opening a pull request, run `./Scripts/test.sh`, `./Scripts/build-app.sh` and
`git diff --check`. For a UI change, describe the manual checks and attach a sanitized screenshot.
The README's [fixture workflow](README.md#development) can exercise the UI without live chats.

In the pull request, explain the problem, resulting behavior, relevant issue and validation. State
any remaining limitations. Contributors do not need a signing certificate or access to secrets.
CI builds and tests on both `macos-14` and `macos-latest`; keep those required check names stable.

## Releases

Releases are maintained from `main` and contain source, not a downloadable app. Change `VERSION`
through a pull request, wait for CI, then tag the merged commit with the matching `vX.Y.Z` tag.
The release workflow checks the version, tests and builds before publishing release notes.
See [the release notes in the internals guide](docs/internals.md#releases-and-updating) for signing
and distribution constraints. A contribution does not require a version bump unless it is the
release preparation itself.
