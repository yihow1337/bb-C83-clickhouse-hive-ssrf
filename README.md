# ClickHouse — DataLakeCatalog Hive metastore ignores `remote_url_allow_hosts` (SSRF)

**Program:** ClickHouse Managed Bug Bounty (Bugcrowd)  
**Asset:** github.com/ClickHouse/ClickHouse (self-hosted builds with Hive support)  
**Severity (researcher):** Medium / High (SSRF)  
**Suggested VRT:** Server-Side Request Forgery (SSRF)  
**Affected version tested:** 26.10.2.103 (official Linux amd64 static build)  
**Fix:** PR [#119353](https://github.com/ClickHouse/ClickHouse/pull/119353) (merged 2026-10-18; backported onto 26.10/26.9/26.8/26.3 branches; **not** in published `v26.10.2.103-stable` or other GitHub Releases available at test time)

## Vulnerability

`CREATE DATABASE … ENGINE = DataLakeCatalog('thrift://HOST:PORT') SETTINGS catalog_type = 'hive'` opens a Thrift TCP connection to `HOST:PORT` without consulting the server’s `remote_url_allow_hosts` filter. An allow-list that correctly blocks `url()` and other URL engines is ignored on this path.

`allow_experimental_database_hms_catalog` is required but is **session-settable** for ordinary users unless an administrator locks it.

## Trust-boundary failure

| Control | Expected | Actual (26.10.2.103) |
|---|---|---|
| `remote_url_allow_hosts` | Deny hosts not listed before any outbound connect | Applied to `url()`; **skipped** in `HiveCatalog::reconnectUnlocked` |
| Experimental HMS flag | Gate feature; allow-list still binds outbound targets | User can `SET` the flag; allow-list still skipped |

## Proof of concept (e2e against released binary)

Environment: official `clickhouse-common-static-26.10.2.103`, config allow-list = `.*\.allowed\.example` only. Script: `poc_e2e.sh`.

**Negative control — `url()` denied:**

```
Code: 491. … URL "http://127.0.0.1:9/x" is not allowed … (UNACCEPTABLE_URL)
```

**Exploit — Hive catalog connects anyway:**

```
SET allow_experimental_database_hms_catalog=1;
CREATE DATABASE ssrf_hive ENGINE = DataLakeCatalog('thrift://127.0.0.1:19083')
  SETTINGS catalog_type='hive', warehouse='synthetic_wh';
→ database created; local listener ACCEPT from ClickHouse
SHOW DATABASES → includes ssrf_hive
```

**Empty allow-list arm:** `Connection refused` (dial attempted) instead of `UNACCEPTABLE_URL` expected by upstream `test_hive_catalog_host_filter` after the fix.

## Code references

Vulnerable (tag `v26.10.2.103-stable`): `src/Databases/DataLake/HiveCatalog.cpp` — `reconnectUnlocked` parses host/port and opens `TSocket` with no filter.

Fixed: same function calls `getContext()->getRemoteHostFilter().checkAndGetCanonicalHostAndPort(...)` before connect; rejects NUL / control characters.

Diff excerpt in evidence package (`diff/`).

## Impact

Outbound SSRF / internal network exposure as the ClickHouse process user, bypassing the documented SSRF control. Prerequisites are `CREATE DATABASE` plus a session `SET` of an experimental setting — not a full administrator role.

## Remediation

Ship #119353 in 26.10.x and active LTS lines. Until then: do not grant `CREATE DATABASE` to untrusted tenants when Hive/DataLakeCatalog is available; mark `allow_experimental_database_hms_catalog` readonly/off in user profiles; or disable Hive at build time if unused.

## Novelty notes

Distinct from 2022 PR #35743 (older Hive engine filter) and from public ClickHouse CVEs in the security changelog (including CVE-2026-116366 RCE). No CVE/GHSA found for the DataLake `HiveCatalog` allow-list omission at report time. Fix PR is public but **unreleased** on current GitHub stable/LTS tags.

## Evidence checklist

- [x] Exact vulnerable release binary (`26.10.2.103`)
- [x] Harmless synthetic listener only
- [x] Negative control (`url()` → UNACCEPTABLE_URL)
- [x] Differential vs fix commit / upstream integration test expectations
- [x] Reproducible `poc_e2e.sh`
