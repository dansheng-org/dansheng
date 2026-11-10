# Official Fudan native login adapter

`login.rs` is a GPL-3.0-or-later Rust protocol adaptation informed by the public
DanXi source pinned at `3c1f5f026fbc7ca50e151865f813cdb381807abe`:

- [neo_login_tool.dart](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/neo_login_tool.dart): NEO V2 JSON endpoints, RSA PKCS#1 v1.5 password encryption, auth methods/chain, token-to-ticket bridge; legacy UIS form protocol.
- [uis_login_tool.dart](https://github.com/DanXi-Dev/DanXi/blob/3c1f5f026fbc7ca50e151865f813cdb381807abe/lib/repository/fdu/uis_login_tool.dart): legacy UIS form fields and fixed failure indicators.
- DanXi academic/card repository constants supply the academic course-table and `/epay` entry paths. Canvas uses the standard `/login/cas` entry on the fixed Fudan eLearning origin; this deployment-specific entry still needs live validation.

Copyright (C) 2021, 2025 DanXi-Dev. Rust adaptation (C) 2026 dansheng-core contributors.
Distributed under GPL version 3 or later, without warranty. See the repository LICENSE.

## Integration

The parent agent owns manifest/lib wiring. Enable this module only through the
optional `login` feature (which includes `services`), keeping normal Host/FFI
builds free of the RSA dependency. Required dependencies:

- optional `reqwest.workspace = true` (0.13 workspace TLS/JSON/form/stream features);
- optional `rsa = "0.9"`, default features (PKCS8 decoding, OS cryptographic randomness);
- optional `base64 = "0.22"`;
- optional `cookie_store = "0.22"`, matching Core (no persistence used here);
- existing `async-trait`, `scraper = "0.24"`, `url`, `serde_json`;
- services `tokio` (macros/time), `rustls = "0.23"` with ring/std/tls12,
  `webpki-roots = "1"`.

Use the existing host `log/max_level_info` policy in the test-lab binary too.
Do not enable wire tracing or log request/response structures or returned cookies.
This adapter does not install a global log subscriber or change global TLS state.

`login(student_id, password, target)` never reads saved credentials or profiles.
Keep its `LoginSession` inside the trusted backend, import into Core's private
session API, then verify using a private read for the selected service. Do not
serialize the session, raw upstream HTML, URLs with tickets or error sources to
the web UI/MCP. Static error code/message are safe to display. There is no
`Debug` or `Serialize` implementation for session/request/response types.

## Scope and limits

- Only Academic (`https://fdjwgl.fudan.edu.cn`), Canvas
  (`https://elearning.fudan.edu.cn`) and Ecard (`https://ecard.fudan.edu.cn`).
  Academic currently means undergraduate; graduate and sports login are excluded.
- Credentials go only to fixed HTTPS NEO `/idp/authn/authExecute` or UIS
  `/authserver/login`; the NEO auth token goes only to the fixed auth engine.
- New isolated in-memory cookie jar per call; no persistence/SSO reuse. RFC domain,
  path, secure and expiry matching. Only cookies actually issued by the selected
  target are exported, with effective paths and absolute expiry preserved and
  original domain identity retained for correct rotation/deletion; the receiving
  Core binds each jar to the selected origin. Identity-provider-only cookies are omitted.
- HTTPS certificate verification with explicit ring and Mozilla trust roots;
  no HTTP fallback, arbitrary origins, custom proxy, JS evaluation, browser port or
  sports requests. Existing OS/TUN networking still applies.
- Manual redirects only: 12 redirects, 20 requests, 10 seconds per request,
  45 seconds total, 1 MiB per body, 4 MiB aggregate, bounded URLs/headers/cookies.
  Password/token POSTs never replay on 307/308. Reqwest retries are disabled.
- One password submission per call. No protocol fallback/retry after rejection,
  timeout, CAPTCHA, OTP, second-factor or weak-password challenge. Authentication
  timeouts are not proof of rejection; the caller must not automatically retry.
- A returned session is import material, never an authenticated-success claim.
  Public 200 responses or standalone target cookies do not complete a login flow.

## Verification

All fixtures are synthetic and offline; no real account, credential, campus login
or user profile was accessed. The implementation worker ran:

- `cargo test -p dansheng-connectors --features login login::tests --lib --locked`:
  **21 passed**, including randomized RSA encryption/decryption, full mock NEO/UIS
  exchanges, fixed target binding, CAPTCHA/2FA exits, password/timeout no-retry,
  nested redirect rejection, cookie issuer/path/expiry preservation, independent
  request/redirect/response limits, and rejection of anonymous-200 session claims.
- `cargo clippy -p dansheng-connectors --features login --lib --tests --locked -- -D warnings`:
  passed.
- `rustfmt --edition 2024 --check crates/dansheng-connectors/src/login.rs`:
  passed.

Parent must independently build/test and inspect the two-file diff before acceptance.
Real campus deployment behavior, Canvas CAS entry compatibility, CAPTCHA/2FA UI
handoff and service-specific private-read verification remain unverified.
