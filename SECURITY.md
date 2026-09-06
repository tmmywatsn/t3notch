# Security policy

## Reporting a vulnerability

Please [report a vulnerability privately through GitHub](https://github.com/tmmywatsn/t3notch/security/advisories/new).
Include the affected version or commit, impact, reproduction steps and a minimal example if
possible. Redact credentials and private chat data; do not send your real T3 Code database.

Please avoid public issues or pull requests containing exploit details before a fix is available.
The maintainer will coordinate a fix and disclosure through the private report. This is a small
volunteer project with no guaranteed response time or bug bounty.

## Supported versions

Security fixes target `main` and the latest release. Older releases do not have separate maintenance
branches; update to the latest release when a fix is published.

## Security boundaries

T3 Notch reads T3 Code's local SQLite database with a read-only connection. It does not execute
commands supplied by chats or send chat contents to a service. The optional release check contacts
GitHub without credentials. See [Privacy](README.md#privacy) for the complete data-access description.

The app relies on T3 Code's private storage schema, which can change. Status-detection and schema
compatibility bugs without a security impact can be reported in ordinary issues. Problems in
T3 Code should be reported using that project's security process.
