# Desktop host

`dansheng-host serve --data-dir <private-directory>` is the desktop database owner.
It opens `Engine`, supplies a system credential platform, listens locally, and ticks persistent
jobs every second. Ctrl+C (also SIGTERM on Unix) stops accepts, drains connections
for two seconds, then aborts remaining work. Core recovery reconciles interrupted
jobs; the host never automatically retries an uncertain external mutation.

Without `--data-dir`, Windows uses `%LOCALAPPDATA%/dansheng`; Linux uses
`$XDG_DATA_HOME/dansheng` or `$HOME/.local/share/dansheng`. It does not create
credentials or application data in a source checkout by default.

The default endpoint is a Unix socket at `<data-dir>/host/ipc.sock` on Linux and a
deterministic `\\.\pipe\dansheng-<hash-of-data-directory>` on Windows. The private
data and host directories use mode 0700 on Unix; tokens use 0600. On Windows their
protected DACL allows only the current user. Named pipes reject remote clients,
use the same current-user DACL, and reserve the first instance to exclude a second
host. Socket files are removed on orderly shutdown. A stale Unix socket after an
unclean exit is intentionally not removed automatically: confirm the old process
has stopped before removing that socket and restarting.

Each IPC frame is `u32` big-endian byte length plus UTF-8 JSON, from 1 byte through
8 MiB. The first frame must be exactly `{"token":"..."}`. It is authenticated by
`Engine::authenticate`; success is a core Response with id `auth` and result
`{"principal":{"id":"...","kind":"..."}}`. Later frames are the core `Request`
and `Response` envelopes. Request principal fields never establish authority.
Malformed request envelopes return `InvalidInput`; invalid frame lengths close
the connection before allocating an oversized payload. Up to 128 connections are
accepted at a time. Authentication has a ten-second deadline.

The host provisions and reuses two files without printing token material:

- `host/owner-token`: registered through the trusted adapter as `owner`, kind `owner`.
- `host/mcp-token`: registered as `desktop-mcp`, kind `mcp`, initially with no grants.

`host/mcp-client.json` contains only `endpoint` and the absolute `token_file` path.
Client configs must point at a local trusted endpoint; treat editing one like
editing the local application's startup settings. Keep token files private.

```powershell
$Profile = Join-Path $env:DANSHENG_TASK_RUNTIME 'profiles/core'
$HostBinary = Join-Path $env:CARGO_TARGET_DIR 'debug/dansheng-host.exe'
# Enter the registered D:/Worktrees/<task>/core task first.
./scripts/start-local.ps1 -Background
& $HostBinary call core.info --data-dir $Profile
& $HostBinary call sources.query '{"kind":"timetable"}' --data-dir $Profile
& $HostBinary call --request '{"id":"inspect","method":"core.info","params":{}}' --data-dir $Profile
& $HostBinary schema
```

`scripts/start-local.ps1` selects the actual `CARGO_TARGET_DIR` and passes the
task profile explicitly. Enter the assigned monorepo worktree using root `scripts/Enter-Dansheng.ps1`, then run Core commands from `core/`. Each checkout owns its external runtime and caches; existing profiles are not copied.

`call` emits the full core Response JSON. `call`, `mcp`, and `schema` never open the
database. IPC disconnection after dispatch returns `OutcomeUnknown`; interrupted
clients invalidate that connection to prevent mixing responses across requests.
No method is retried automatically.

## MCP

`dansheng-host mcp --data-dir <directory>` uses **rmcp 3.9** stdio and the dedicated
MCP config. `--client-config <path>` selects another explicitly provisioned MCP
identity. An owner/client token is rejected; the adapter never falls back to the
owner token. Stdout is reserved for MCP messages.

The tools are `sources_query`, `search_query`, `jobs_list` (core `jobs.status`),
`events_list` (core `events.poll`), and controlled `core_call`. Resources expose
sources, jobs, plugins, events, and the wire schema. `core_call` exposes core info,
capability checks, account/auth status, source/search queries, plugin listing/run,
job status/schedule/run/cancel/resume, event polling and declarative UI lookup. It never
exposes grants, client registration, credential import, package installation, raw
HTTP, browser evaluation or backup. Every exposed operation still passes through
core policy using the authenticated MCP principal.

An owner can grant reads explicitly, for example:

```powershell
& $HostBinary call permissions.set '{"subject":"desktop-mcp","grant":{"capabilities":["sources.read","jobs.status","events.poll","plugins.list"],"account_ids":["campus"],"source_ids":["fudan.timetable"]}}' --data-dir $Profile
```

Use actual local account/source identifiers in the grant. `sources.read` alone
does not authorize global anonymous records; explicit `source_ids` scopes
cross-plugin reads of records without an account, while `account_ids` controls
account data. Core independently applies the current grant to each query.

Runs additionally need `plugins.run` or the relevant `jobs.*` capability and an
action grant `plugin:<plugin-id>:<action>`. Mutating actions also require the
explicit `execute:<plugin-id>:<action>` grant. Plugin grants and account access
remain independently checked by core. Scheduling does not confer owner authority.

The implementation uses the [official Rust MCP SDK](https://github.com/modelcontextprotocol/rust-sdk).
The desktop provider advertises internal `vault.set`, `vault.get`, `vault.delete`
ports. Set accepts `{key,value}`; get/delete accept `{key}`. Get returns `{value}`
(null for an absent key), while set/delete return `{ok:true}`. Values are JSON
stored in Windows DPAPI-encrypted private profile files or Linux Secret Service
using keyring-rs. Windows credentials are not limited to Credential Manager's small
blob size; the restart test includes a session larger than 100 KiB.
The namespace is scoped to the data directory; keys are hashed. Native calls run
on blocking workers and errors never include keys, values, or backend error text.
Locked/missing system stores return `CapabilityUnavailable`. Platform size limits
return `InvalidInput`; no plaintext file, kernel-only keyring, or mock fallback is
used. These ports are for internal core calls; they are not host wire/MCP methods.

Browser brokers remain supplied by the embedding platform; the desktop host
returns explicit missing-capability errors until one is provided.

## Offline verification

`cargo test -p dansheng-host` covers framing boundaries, stable token provisioning,
first-frame authentication, malformed envelopes, principal spoofing, actual local
IPC, MCP owner-token rejection and grant enforcement, a local JS scheduler fixture,
and a clean restart reusing the owner token. These tests contact no school service.
Linux transport and permission tests run only on Unix; Windows transport tests use
real local named pipes. Cross compilation is a separate check from executing tests.
