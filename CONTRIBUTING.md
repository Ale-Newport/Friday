# Contributing to Friday

Thanks for wanting to help! Friday is a native macOS voice assistant written in Swift, with a small Python sidecar for
the browser agent. Contributions in **English or Spanish** are welcome — code, tests, translations, docs and bug
reports alike.

## How changes get in

`main` and every other branch in this repository are protected. Contributors work from a **fork** and open a **pull
request**; every pull request needs the maintainer's review (CODEOWNERS) and green CI before it is merged. Stale
approvals are dismissed when new commits are pushed, and contributors cannot approve their own changes.

1. Fork the repository and create a branch from `main` (`fix/percent-parsing`, `feat/spanish-units`, …).
2. Make your change with tests (see below).
3. Run the checks locally.
4. Open a pull request using the template and link the issue it closes.

Not sure where to start? Look for issues labelled
[`good first issue`](https://github.com/Ale-Newport/Friday/labels/good%20first%20issue) or
[`help wanted`](https://github.com/Ale-Newport/Friday/labels/help%20wanted), or ask in
[Discussions](https://github.com/Ale-Newport/Friday/discussions).

## Setting up

Requirements: macOS 26+ on Apple Silicon, Xcode 27 (Swift 6.4, macOS 27 SDK), [XcodeGen](https://github.com/yonaskolb/XcodeGen) and
[uv](https://docs.astral.sh/uv/).

```bash
brew install xcodegen uv
make bootstrap   # pinned + checksum-verified speech libraries and models, the Python sidecar, Friday.xcodeproj
make run         # build and launch Friday.app (Debug)
```

`make bootstrap` downloads only from pinned upstream releases and verifies every archive's SHA-256 before installing
it. No account or key is needed. See [docs/SETUP.md](docs/SETUP.md) for the full walkthrough.

## Checks to run before a pull request

```bash
swift build && swift test                                  # Swift package (no microphone, key or network needed)
cd Sidecar && uv run ruff check . && uv run pytest tests --ignore=tests/integration -q
shellcheck --severity=warning Scripts/*.sh
```

Tests that need the downloaded speech models skip themselves when the models are absent; with the models present some
of them check latency and can be slow on a busy machine.

## Guidelines

* **Keep the module boundaries.** `ArchitectureBoundaryTests` enforces which module may import which; the map is in
  [ARCHITECTURE.md](ARCHITECTURE.md).
* **Every action is a typed tool.** New capabilities go through `ToolDescriptor` + an `AppIntegration`, with
  validation, a safety level and a verified result. Anything that sends, deletes, buys, uploads or publishes must ask
  for approval.
* **Bilingual by default.** User-facing text has English and Spanish versions; parsers accept both.
* **Tests:** new code comes with tests (Swift Testing for new suites). Prefer fakes over real apps, network or audio.
* **Style:** follow the surrounding code. Python is checked with `ruff` (configuration in `Sidecar/pyproject.toml`).
* **Commits:** small, focused, with a message that says what changed and why.
* **No secrets.** Never commit keys or tokens; CI runs gitleaks and GitHub push protection is on. Credentials belong
  in the Keychain.

## Reporting bugs and proposing features

Use the [issue templates](https://github.com/Ale-Newport/Friday/issues/new/choose). For security problems, follow
[SECURITY.md](SECURITY.md) instead of opening a public issue.

By contributing you agree that your contributions are licensed under the [MIT License](LICENSE) and that you follow
the [code of conduct](CODE_OF_CONDUCT.md).
