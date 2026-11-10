# dansheng-core implementation roadmap

Approved design: local-first, UI-independent Rust core + official connectors + mediated JavaScript plugins. GPL-3.0-or-later. Fudan first; Android embedded, Windows/Linux local service. User requested MCP queries and controlled execution from v0.1. Sports is the first complex plugin after the basic cross-platform loop, initially Android WebView.

## Milestones and release gates

| Milestone | Scope | Required evidence |
|---|---|---|
| M0 | Pinned public DanXi/Dela + selected local sports snapshot, source attribution, workspace/toolchain/CI/contracts | Build actual Rust library, load SQLite and QuickJS on Windows/Linux/Android; distinguish compiled vs executed |
| M1 / 0.1 | Accounts/session broker, HTTP, persistent data/jobs, grants, JS install/run, declarative UI, local IPC/FFI/MCP | Same JS package on desktop and Android; login/data/save/query/UI-description/MCP; negative permission/cancellation/restart cases |
| M2 / 0.2 | Android page-context browser port, wake-up/foreground lifecycle, official fudan-sports plugin | Page fetch/XHR semantics, interactive auth, account switch, partial results/cancel/deadline/reconciliation; no unapproved real reservation |
| M3 / 0.3 | Fudan campus connectors + generic Canvas and Fudan configuration | Undergraduate/postgraduate timetable, exams/grades, campus card/QR, electricity, rooms, occupancy, PE, bus, notices; second real source |
| M4 / 0.4 | IMAP/MIME/SMTP, drafts/attachments, managed files, TODO/calendar/ICS, activities and full-text search | UIDVALIDITY reset, interrupted sync, download recovery, Chinese short queries, first-sync notification suppression |
| M5 / 1.0 | Signed plugin catalog/update/rollback, grant changes, backup/restore, forum/course-review connectors | Failed install/migration recovery, trust-policy tests, source/license manifest and reproducible artifacts |

Later: source-verified library loans/renewal, assignment submission, video/transcripts, desktop browser providers, macOS/iOS. No built-in LLM/agent, SSH/terminal, product UI, cloud sync server, Node runtime or mandatory browser distribution.

## Reference boundaries

Public baselines and local commit are pinned in reference/manifest.json. Local source contains a WebView-dependent booking client, page fetch/XHR, five-minute native wake preparation, sixty-second browser preload, a 300ms first-shot delay and a five-minute attempt window. Keep such policy in the sports plugin. Core schedules generic jobs and exposes browser/platform ports; it must not synthesize WAF success or assume copying cookies makes Rust HTTP equivalent.

Dela's cached title search is not course-document full-text search. Its server-draft deletion behavior is product-specific and must not be copied into mail synchronization. Source-specific data/identifiers/timestamps remain distinct, rather than being collapsed into a universal CampusData object.

## Evidence policy

Track offline contract tests, platform build, emulator execution, and authenticated live-campus verification separately. Never mark a capability complete solely from an interface stub or synthetic fixture. Missing platform features must return CapabilityUnavailable. Auth challenges pause dependent tasks. Unknown remote write outcomes require reconciliation, never blind automatic retry.
