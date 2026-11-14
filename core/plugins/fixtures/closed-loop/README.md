# Synthetic local closed-loop package

This is a verification package, not a school connector or a real login test.
Windows native release and Android JNI must install these same four files
(`manifest.json`, `main.mjs`, `LICENSE`, `README.md`) without rewriting the origin,
module, capabilities or input. The host serves its own loopback on each platform;
there is no emulator-to-host forwarding and no external network service.

Bind **only** `127.0.0.1:19765`, with exclusive ownership, and fail if occupied.
Never terminate another process or silently choose another port. Accept only
`GET /fixture`. Require `Authorization: Bearer synthetic-fixture-bearer`, whose
literal value is public synthetic test data, never a real credential. Respond:

```json
{"account_id":"fixture-account","id":"course-1","title":"Synthetic course","count":2}
```

Use HTTP 200, `Content-Type: application/json`, exact UTF-8 `Content-Length`,
and `Connection: close`. Never log the request headers. The server records only
request count and whether method/path/authentication matched. No response header
or credential is included in plugin storage, canonical sources, UI or results.

Install/enable `fixture.closed-loop` and grant its exact declared capabilities,
`account_ids:["fixture-account"]`, `origins:["http://127.0.0.1:19765"]`, and
`allow_private_network:true` to `plugin:fixture.closed-loop`. Run as owner with
the identical input `{"account_id":"fixture-account"}` for both actions.

1. Run `sync` without a session. Expected result:
   `{"status":"auth_required","account_id":"fixture-account","challenge":"AuthenticationRequired"}`.
   It must not issue any HTTP request. `readCache` returns null.
2. The trusted fixture host calls `auth.session.set` with `account_id` above,
   `origin:"http://127.0.0.1:19765"`, `bearer:"synthetic-fixture-bearer"` and
   `persist:false`. `auth.status` reports `verification:"local_credentials_only"`;
   this does not prove a school login. Current Native HTTP accepts this synthetic
   loopback bearer. If that security policy changes to deny it, fail visibly;
   do not relax security or silently substitute another transport.
3. Run `sync`; exactly one authenticated loopback GET is expected. The plugin
   itself performs private storage, `sources.upsert/query`, and `ui.publish`.
   Expected normalized result (object key order is immaterial):

```json
{"status":"synced","account_id":"fixture-account","source_id":"fixture.closed-loop.courses","external_id":"fixture-account:course-1","title":"Synthetic course","count":2,"records":1}
```

4. `readCache` returns the same object without `status` and `records`. It does not
   contact HTTP. Close/reopen the core on the same synthetic data directory and
   rerun `readCache` to verify SQLite persistence; the in-memory credential does
   not persist and `auth.status.authenticated` must be false after reopen.
5. Owner `sources.query` with source/account/external IDs above returns exactly
   one row owned by `plugin:fixture.closed-loop`, kind `fixture.course`, and
   `data:{"title":"Synthetic course","count":2}`. Normalize away the core row's
   `updated_at`; the plugin's own results contain no timestamps.
6. Owner `ui.get` with `principal:"plugin:fixture.closed-loop",id:"summary"`
   returns:

```json
{"type":"card","title":"Synthetic course","value":2,"account_id":"fixture-account","source_id":"fixture.closed-loop.courses","external_id":"fixture-account:course-1"}
```

For desktop MCP read-back, grant the reader account/source access and use the
actual authorization contract for UI descriptions. Do not impersonate owner or
weaken UI namespaces to manufacture a successful read. Android does not implement
an MCP server in this fixture.

Package identity is SHA256 over a UTF-8, no-BOM inventory: ordinal-sort the four
top-level filenames; each line is lowercase file SHA256, two spaces, filename,
LF. Hash that inventory. Record both inventory and artifact hashes outside this
package to avoid a self-referential digest. Normalize result objects recursively
by ordinal-sorted keys, serialize compact UTF-8 JSON, and hash without a newline.

License: GPL-3.0-or-later, see LICENSE. This original synthetic fixture contains
no reference checkout files, real identity, credentials, or campus response data.
