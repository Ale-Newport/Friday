# Security policy

Friday runs with access to your microphone, your Mac's apps and data, and a browser. Security reports are taken
seriously and handled privately.

## Supported versions

| Version | Supported |
|---|---|
| `main` and the latest release | ✅ |
| older releases | ❌ — please upgrade first |

## Reporting a vulnerability

**Please do not open a public issue for security problems.**

Report privately through GitHub: **[Security ▸ Report a vulnerability](https://github.com/Ale-Newport/Friday/security/advisories/new)**
(private vulnerability reporting is enabled for this repository).

Please include what you found, how to reproduce it, the affected version or commit and the impact you expect. You
will get an acknowledgement within 7 days and a status update at least every 14 days until it is resolved. Once a fix
is released, the advisory is published with credit to you unless you prefer otherwise.

## Scope

In scope: the Friday app and `fridayctl`, the Python sidecar and its local API, the build and fetch scripts, and the
GitHub Actions workflows in this repository.

Particularly interesting:

* anything that lets a web page, document, e-mail or other content **drive Friday's tools without the user's
  approval** (prompt injection that bypasses the approval prompts for sending, deleting, purchasing, uploading…);
* access to the sidecar's loopback API or the `fridayctl` Unix socket from another user, another origin or without
  the token;
* credential exposure (ChatGPT/OpenAI tokens, API keys, Picovoice keys) in logs, crash reports, the transcript or
  network traffic;
* bypasses of the checksum verification in `Scripts/fetch-*.sh`.

Out of scope: issues that need an already-compromised user account or physical access to an unlocked Mac, and
reports from automated scanners without a demonstrated impact.

## How Friday protects you (summary)

* Credentials live in the **macOS Keychain**; nothing secret is written to disk in plain text or committed.
* The sidecar binds **127.0.0.1 only**, requires a random **bearer token** per launch (constant-time comparison) and
  rejects unexpected `Host`/`Origin` headers (DNS-rebinding protection).
* Actions that send, delete, buy, upload or publish ask for **explicit approval** first.
* Native libraries and models are **pinned and SHA-256 verified** before installation.
* The repository uses CodeQL, Dependabot, secret scanning with push protection and gitleaks in CI.
