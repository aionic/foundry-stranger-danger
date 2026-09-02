# Microsoft Foundry cross-project isolation - customer evidence summary

- Source run: `20260903T220650154Z-14a2c4a0`
- Collected: 2026-09-03T22:10:57.7946099Z
- Status: **passed**
- Scope: `cosmos-storage-search`
- Configuration: `hardened`

## Validated assertions

- Deployment configuration passed: **True**
- Cosmos and Blob access matrix passed: **True**
- Expected Search findings observed: **True**

## Resource attribution

| Project | Cosmos containers | Classic | Modern | Blob containers |
|---|---:|---:|---:|---:|
| alpha | 5 | 3 | 2 | 2 |
| bravo | 5 | 3 | 2 | 2 |

## Direct data-plane matrix

| Probe | Alpha Cosmos | Alpha Blob | Bravo Cosmos | Bravo Blob |
|---|---|---|---|---|
| `broad` | ALLOW | ALLOW | ALLOW | ALLOW |
| `scoped-alpha` | ALLOW | ALLOW | DENY | DENY |
| `scoped-bravo` | DENY | DENY | ALLOW | ALLOW |

## AI Search

- Single-index role: selected index **ALLOW**; other project index **DENY**
- Service-scoped role: project A **ALLOW**; project B **ALLOW**
- Index-scoped enforcement observed: **True**
- Service-scoped reach across projects observed: **True**
- Generated index name attributable to a project: **False**

## Evidence handling

This bundle is a sanitized derivative. The source manifest and artifact SHA-256 hashes are retained in `evidence-summary.json` so the assessment owner can trace this summary to the internally retained raw run. Operational identifiers and raw request details are intentionally omitted.

The source manifest recorded a dirty Git working tree. Each evidence producer and raw artifact is nevertheless bound by its own SHA-256 hash; those hashes are included in the JSON summary.
