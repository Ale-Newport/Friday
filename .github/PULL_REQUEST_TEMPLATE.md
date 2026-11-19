## What does this change?

<!-- One or two sentences. Link the issue it closes: "Closes #123". -->

## How was it tested?

- [ ] `swift build && swift test`
- [ ] `cd Sidecar && uv run ruff check . && uv run pytest tests --ignore=tests/integration -q` (if the sidecar changed)
- [ ] Tried in the running app (describe what you said or typed and what happened)

## Checklist

- [ ] New behaviour has tests; user-facing text exists in English and Spanish.
- [ ] Actions that send, delete, buy, upload or publish still ask for approval.
- [ ] No secrets, personal data or generated files are committed.
- [ ] Docs/CHANGELOG updated if users will notice the change.

<!-- Every pull request is reviewed by the maintainer (CODEOWNERS) before it can be merged. Thank you! -->
