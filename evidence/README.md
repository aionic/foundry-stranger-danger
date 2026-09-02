# Evidence package

Raw evidence is generated locally and is not committed. This directory tracks this guide,
`.gitkeep`, and reviewed sanitized bundles under `published/`.

## Accepted customer evidence

- [Run `20260903T220650154Z-14a2c4a0`](published/20260903T220650154Z-14a2c4a0/REPORT.md) - complete
  Cosmos, Storage, and Search evidence collected on 3 September 2026.

## Generate a run

```powershell
.\scripts\12-collect-evidence.ps1
```

The collector invokes the agent, inventory, cross-access, and Search tests unless explicitly
skipped. It writes the latest artifacts at the root and archives an immutable copy under:

```text
evidence/runs/<UTC-run-id>-<isolation-mode>/
```

Each archived run contains:

| Artifact | Purpose |
|---|---|
| `manifest.json` | Run ID, UTC timestamp, status, commit, dirty-tree flag, producer hashes, deployment identity, assertions, and artifact hashes |
| `REPORT.md` | Human-readable run summary |
| `agents.json` | Agent invocation metadata and distinct canary responses |
| `isolation-inventory.json` | Discovered Cosmos/Blob resources and actual Cosmos/ARM grants |
| `cross-access-matrix.json` | Per-probe, per-project, per-store outcomes and verdicts |
| `cross-access-matrix.md` | Readable matrix generated from the JSON |
| `search-isolation.json` | Vector-store IDs, exact tested indexes, ownership established by create-and-diff, and Search outcomes |
| `source/` | Hash-bound copies of evidence producers, deployment orchestration, Terraform sources, provider lock, effective tfvars, and the modern-container lifecycle marker |

The manifest also records Terraform, Azure CLI, and PowerShell versions. This is required when the
working tree is dirty: a base commit alone cannot identify the code that produced the evidence.

Validate an archived run without contacting Azure:

```powershell
.\scripts\14-validate-evidence.ps1 `
  -EvidenceDir .\evidence\runs\<run-id>-<mode>
```

## Evidence rules

A run is valid only when all of these hold:

1. Every project has five attributable Cosmos containers and two attributable Blob containers.
2. Broad controls can read both projects, proving the data path is reachable.
3. Scoped probes can read their own project for both Cosmos and Blob.
4. Scoped probes are denied against the other project for both stores.
5. Network-origin refusals are classified `BLOCKED`, never `DENY`.
6. Search records the exact tested index for each project instead of selecting an unknown index.
7. Every artifact matches the run ID and SHA-256 hash in the manifest.

`status: passed` means the expected validation-lab outcomes were reproduced. It does not mean the
shared Search topology is recommended for production; service-scoped Search access spanning both
projects is one of the expected findings.

## Publishing customer evidence

Do not publish the raw directory directly. It contains subscription/resource identifiers,
principal IDs, project endpoints, and operational metadata. Create a reviewed, sanitized evidence
bundle from one manifest-valid run and retain the original manifest and hashes in the assessment
record. Never include Terraform state or probe client secrets.

Create and validate the sanitized derivative with:

```powershell
.\scripts\15-publish-evidence.ps1 `
  -SourceEvidenceDir .\evidence\runs\<run-id>-<mode>
```

The historical unmanifested files that may exist in a developer workspace predate this evidence
contract. Treat them as research inputs, not as a distributable assurance package.
