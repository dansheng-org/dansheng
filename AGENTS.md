# dansheng-core contributor instructions

- Implement the approved local-first Rust core plan. Production UI is a separate project.
- Preserve `C:/Code/danxi`; reference checkouts are read-only. Never copy credentials, user data, or generated build files into this repository.
- Shared core must not depend on Flutter, an embedded browser, MCP, or a school-specific service. Browser execution, credentials, wake-up and notifications are platform ports.
- School endpoints and sports strategies belong to official connectors/plugins. Browser-backed requests must execute in the authenticated page; do not silently substitute Rust HTTP.
- No Node.js or Chromium runtime in released core artifacts. JS plugins run through mediated host APIs and explicit grants.
- Treat external write timeouts as uncertain outcomes; reconcile before retrying. Do not execute live reservations, cancellations, mail sends, or other remote mutations without concrete user authorization.
- Never expose secrets in logs, exported diagnostics, fixture data or tests.
- Use meaningful offline fixtures and integration tests. Report cross-compilation, emulator tests, and real-service tests separately.
- Coordinate parallel edits using disjoint file ownership. Do not overwrite another worker's changes or commit unless asked.
- Antigravity workers must use the user's required headless protocol: cwd is the project root; pass `--add-dir <absolute project> --dangerously-skip-permissions --output-format json --print-timeout 30m --print <prompt>`. Persist every returned conversation_id. Continue a worker with its exact `--conversation` ID and verify the returned ID matches. Use separate conversations and disjoint file scopes for parallel workers, never concurrent continuations of the same ID. Main must independently inspect requirements, files, Git diff, builds/tests and out-of-scope edits; summaries alone are not acceptance evidence.
