# Claude Code: Dansheng Core

@AGENTS.md

Read this repository's `AGENTS.md`, `docs/DEVELOPMENT_WORKFLOW.md`, and any provided
task notes before editing. This is one of two independent product repositories.
Never make an outer Git repository, edit `main`, write another agent's worktree,
or change credentials, remotes, historical tags, running services or devices.

Open the Git worktree supplied by the user or Herdr. New tasks use `D:/worktree`
as the user's preferred root; creation, location and cleanup belong to the user or
Herdr. Inspect Git registration/common directory and status; no extra manager,
DS numbering or TASK.md is required. Automatically prepare isolated build and
runtime resources. Do not create, move or remove a checkout unless assigned.
Implement, test, and perform commits/merges when the user requests them; that
request is authorization and does not require repeated confirmation. Report local
integration separately from pushing or publishing. Retained DS-001 is historical.

Use PowerShell 7. Run applicable Rust checks and `tools/workspace/tests/Test-Workspace.ps1`
for management changes. Preserve the pinned Windows toolchain/FFI constraints;
keep toolchain binaries read-only and caches/targets per task. Report the diff,
validation, cross-repository dependency and remaining approvals.
