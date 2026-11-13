@AGENTS.md

# Claude Code in dansheng-app

Read AGENTS.md and any provided task notes before changing files. This is an independent
App repository; the parent workspace is not a Git monorepo. Use the existing
authorized Git worktree. Native tool branch names are accepted; DS numbering and
extra manager adoption are optional. Do not write main, mutate a
peer worktree, stage/commit/merge/push, change remotes or clean files without approval.

If no worktree has been provided and creation is authorized, Claude's worktree mode
may be used. Do not call `claude --worktree` to duplicate an already managed task.
Check the resulting Git worktree registration, branch/HEAD and common directory
before writing. Automatically prepare the worktree's isolated runtime/build resources;
manual New/Initialize/Enter commands are not a user prerequisite.

Keep the current Rust C ABI/JNI/AAR/Pigeon boundary. Use the exact Core dependency
and task-scoped runtime paths. No credentials, source-wide copying, new FFI stack,
production signing, real reservations or device operations are authorized by setup.

Use the local checks listed in AGENTS.md; report actual commands and results.
An unexecuted CI workflow and an unversioned local native artifact are not a release.
