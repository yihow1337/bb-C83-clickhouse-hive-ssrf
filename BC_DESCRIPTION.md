## Summary

On ClickHouse **26.10.2.103** (and other current stables/LTS without the fix), creating a `DataLakeCatalog` database with `catalog_type = 'hive'` connects to the attacker-chosen Thrift metastore URL **without consulting** `remote_url_allow_hosts`.

A user who can `CREATE DATABASE` and set `allow_experimental_database_hms_catalog = 1` (session-settable by default) can force the server to open a TCP connection to an arbitrary host:port, even when the allow-list is configured to deny that host. The same allow-list correctly blocks `url()` / other URL table functions (negative control).

## Root cause

`DataLake::HiveCatalog::reconnectUnlocked` parses `base_url` and calls `TSocket(host, port)` / `transport->open()` with **no** `RemoteHostFilter` / `checkAndGetCanonicalHostAndPort` call. The Hive path was covered for the older Hive engine in 2022 (PR #35743) but the newer DataLake `HiveCatalog` omitted the check.

Fixed in PR [#119353](https://github.com/ClickHouse/ClickHouse/pull/119353) (merged 2026-10-18 to master; backported to 26.10/26.9/26.8/26.3 branches as 26.10.3.x etc.) — **not** present in published tag `v26.10.2.103-stable` (2026-10-24) or other GitHub releases current at test time.

## Affected

- Confirmed: official `clickhouse-common-static` **26.10.2.103** (Hive support compiled in).
- Likely: 26.9.x / 26.8 LTS / 26.3 LTS published tags without the #119353 backport.
- Fixed in: master after #119353; release notes claim inclusion starting `26.10.3.13` / `26.9.26.23` / `26.8.35.23` / `26.3.61.16` (those tags were **not** published on GitHub Releases at report time).

## Prerequisites

1. ClickHouse build with Hive/Thrift support (official static builds include it).
2. Attacker can `CREATE DATABASE` and `SET allow_experimental_database_hms_catalog = 1` (default profile allows the setting).
3. Server has `remote_url_allow_hosts` configured (the control the admin relies on for SSRF). If the section is absent, the filter is uninitialized and allows all hosts by design — the bug is that an **explicit** allow-list is still ignored for Hive.

## Steps to reproduce (synthetic)

See `poc_e2e.sh` in the evidence package.

Abbreviated:

1. Configure `<remote_url_allow_hosts><host_regexp>.*\.allowed\.example</host_regexp></remote_url_allow_hosts>`.
2. Negative: `SELECT * FROM url('http://127.0.0.1:9/x', …)` → **UNACCEPTABLE_URL**.
3. Start a local TCP listener on `127.0.0.1:19083`.
4. `SET allow_experimental_database_hms_catalog=1; CREATE DATABASE ssrf_hive ENGINE = DataLakeCatalog('thrift://127.0.0.1:19083') SETTINGS catalog_type='hive', warehouse='synthetic_wh';`
5. Listener **ACCEPT**s the connection; database `ssrf_hive` appears in `system.databases`.
6. Empty allow-list arm: same CREATE yields `Connection refused` (filter not applied) instead of `UNACCEPTABLE_URL` (expected after the fix; see upstream `test_hive_catalog_host_filter`).

## Impact

**Server-Side Request Forgery (High–Medium).** Bypass of the documented host allow-list for outbound connections: internal network port probe / reachability to Thrift or TCP services as the ClickHouse OS user. No admin role required beyond ordinary `CREATE DATABASE` plus a session `SET` of an experimental flag.

## Suggested fix

Already landed upstream in #119353: call `getRemoteHostFilter().checkAndGetCanonicalHostAndPort` before opening the Thrift socket. Please publish patched 26.10 / LTS builds.

## CVSS (proposed)

`AV:N/AC:L/PR:L/UI:N/S:C/C:L/I:N/A:N` ≈ **5.0–6.4 Medium** (scope change via SSRF to other hosts; confidentiality limited to what a TCP connect / thrift handshake reveals). With cloud metadata or sensitive internal HTTP-on-TCP services reachable, treat as **High**.

## VRT

Server-Side Request Forgery (SSRF) > Cloud Instance Metadata / Internal services (as applicable) — researcher estimate **P2–P3**.
