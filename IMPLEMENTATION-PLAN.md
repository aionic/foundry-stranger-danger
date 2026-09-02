# Customer assurance package: status and release plan

**Updated:** 8 September 2026  
**Beads issues:** `fps-1my` (`closed`), `fps-51b` (`closed`)  
**Branch:** `main`  
**Baseline commit:** `2cc88f7`  
**Current state:** implementation, architecture approval, PNG rendering, fresh Azure evidence, and disposable-lab teardown complete

## Objective

Deliver a clear, directive, evidence-backed customer assessment of Microsoft Foundry cross-project
data isolation. The package must distinguish:

- the validation lab from the recommended production architecture;
- direct data-plane behavior from persistent management-plane authority;
- measured facts from configuration checks, Microsoft-sourced facts, and recommendations;
- a successful local implementation from a customer-release evidence claim.

## Implemented

### Customer package

| Artifact | Current role | Status |
|---|---|---|
| `README.md` | Two-minute result, decision table, scope, and navigation | Complete |
| `docs/00-report.md` | Canonical assessment, findings, actions, evidence record, limitations | Complete; final technical assessment |
| `docs/01-architecture.md` | Lab, measured boundary, target state, decisions, Well-Architected review | Complete; approved and rendered |
| `docs/03-validation-runbook.md` | End-to-end validation, evidence, troubleshooting, publication, teardown | Complete |
| `docs/05-hardening-guide.md` | Audit, target topology, remediation, verification, recovery, completion | Complete |
| `docs/02-isolation-model.md` | Anchor-preserving compatibility pointer | Complete |
| `docs/04-findings.md` | Anchor-preserving compatibility pointer | Complete |
| `evidence/README.md` | Evidence structure, validity rules, publication controls | Complete |

The canonical report now includes four findings:

1. database-scoped Cosmos access expands direct read reach;
2. constructed Blob scopes can be silently ineffective;
3. shared Search is not a durable Foundry project boundary for vector data;
4. persistent provisioning roles keep shared services inside one trust boundary.

The fourth finding is important: Blob ABAC and Cosmos container RBAC constrain direct data-plane
requests, but project identities retain service-wide provisioning/management roles in the shared lab.
Separate backing resources are required where project identities are mutually untrusted.

### Assurance implementation

- Cosmos and Blob outcomes are evaluated independently per project and per container.
- Empty or mixed container results cannot collapse into `ALLOW` or `DENY`; they become failure.
- Standalone matrix runs exit nonzero for unexpected outcomes and use a distinct exit for network
  blocking.
- HTTP `401` is `ERROR`, authorization `403` is `DENY`, and network-origin `403` is `BLOCKED`.
- Own-project `ALLOW` controls are required before cross-project `DENY` is accepted.
- Project Cosmos grants are checked against the recorded mode.
- Project Blob validation requires exactly one direct conditioned owner role and the exact
  Terraform-generated condition expression for that project's GUID prefix.
- Inherited or extra Blob data roles applying to the account invalidate the configuration.
- Agent evidence records API version, deployment identity, canary, timestamp, and source run.
- Reused agent evidence is validated before `-SkipAgents` proceeds.
- Agent creation is retry-safe: an existing named canary agent is reused.
- Search ownership uses bounded serialized create-and-diff and never guesses an index.
- Temporary Search role assignments are removed in `finally`; cleanup failure invalidates the run.
- Modern Cosmos container discovery uses bounded polling instead of fixed sleeps.
- Run IDs combine millisecond UTC time and a nonce, and archive directories cannot overwrite.
- Manifests record scope, source commit/dirty state, producer hashes, artifact hashes and byte counts,
  deployment identity, agent source, and assertions.
- Offline validation checks manifest declarations against artifact contents.

### Operational hardening

- Deployment preflight resolves the model and region from Terraform configuration.
- Azure privilege discovery includes inherited/resource-scoped assignments.
- Teardown verifies Azure CLI subscription against Terraform state.
- The user-authored ARM effective-access preflight is preserved and now fails closed if the decision
  cannot be obtained.
- Teardown targets only the Foundry account and probe applications captured from this Terraform
  state; it no longer deletes every similarly named probe app.
- Teardown exits nonzero if destroy, purge, app cleanup, or resource-group cleanup remains incomplete.
- Explicit recovery modes handle provider refresh/delete restrictions, recover exact scope from
  structured state after a partial destroy, and clear stale state only after Azure cleanup succeeds.
- Tracked Terraform examples contain no personal subscription or owner values.

### Diagram contracts

The authoritative Stage 1 Mermaid sources are:

1. `docs/diagrams/validation-lab-topology.mmd`
2. `docs/diagrams/measured-authorization-boundary.mmd`
3. `docs/diagrams/recommended-customer-target-state.mmd`
4. `docs/diagrams/bootstrap-harden-verify-sequence.mmd`
5. `docs/diagrams/test-controls-and-evidence.mmd`

All five pass pinned Mermaid CLI `11.16.0` validation and were explicitly approved. Final
3840 x 2160 Azure-native PNGs are under `docs/diagrams/rendered/`, use official Microsoft Azure
Public Service Icons V24, and pass source-lock, icon/output hash, dimension, pixel, semantic, and
visual QA. Broad versus project-constrained paths and the direct-data-plane scope are explicit.

## Automated quality gate

Run:

```powershell
npm test
```

It validates:

- every PowerShell script under `scripts/` and `tests/` parses;
- Terraform formatting;
- Terraform configuration;
- sanitized evidence-contract fixtures and failure mutations;
- all local Markdown targets and heading anchors;
- all five Mermaid contracts by rendering temporary PNG previews;
- Git diff whitespace hygiene.

Current result: **PASS**.

Evidence tests cover:

- valid hardened evidence;
- own-project Blob denial;
- cross-project Blob allow;
- network blocking;
- collection run mismatch;
- hash tampering;
- missing Search attribution;
- invalid canary;
- broad project Cosmos grant;
- unconditioned Blob grant;
- wrong Blob condition text;
- inherited project Blob role;
- partial container access;
- ambiguous Search discovery;
- authentication/network/authorization response classification.

## Release gates

### Gate 1: explicit architecture approval — complete

**Owner:** accountable customer architecture/security reviewer.  
**State:** approved on 3 September 2026 and locked in `docs/diagrams/approved-contract-lock.json`.

### Gate 2: fresh manifest-valid Azure evidence — complete

**Owner:** security validation owner.  
**State:** complete. Release run `20260903T220650154Z-14a2c4a0` passed the raw evidence validator.
Its archive retains 9 producer snapshots, 17 Terraform/deployment source snapshots, and recorded
Terraform, Azure CLI, and PowerShell versions. The sanitized tracked bundle is under
`evidence/published/20260903T220650154Z-14a2c4a0/`, and the canonical report names the accepted run.

### Gate 3: final Azure-native PNGs — complete

**Owner:** architecture document owner.  
**State:** complete. Approval lock, official icon provenance, deterministic renderer, five PNGs,
render manifest, captions, alt text, and persistent validation are committed to the working tree.

### Gate 4: disposable lab teardown — complete

**Owner:** security validation owner.  
**State:** complete. Independent checks confirm the dedicated resource group is absent, the Foundry
account is not soft-deleted, no suffix-matched probe applications remain, Terraform state contains
zero entries, and the generated modern-container lifecycle marker is absent.

## Residual limitations to retain

These are architecture facts, not unfinished implementation defects:

- The lab measures direct data-plane authorization. It does not exercise management-plane escalation
  by a compromised project identity.
- Shared Storage and Search retain project provisioning roles with service-wide management actions.
- Shared-service hardening is suitable only inside one accepted trust boundary.
- The tested Foundry vector-store API did not expose a durable project-to-index mapping.
- Production private networking, DNS, resilience, backup, DR, performance, and cost were not tested.
- Foundry/Cosmos/Storage ran in `westus3`; Search ran in `eastus` because of capacity. This was not a
  regional-resilience test.

## Maintenance commands

```powershell
bd prime
bd show fps-1my
Get-Content .\IMPLEMENTATION-PLAN.md
npm test
```

## Definition of done

The Beads issue can close only when:

- the current Mermaid contracts are explicitly approved;
- one fresh complete Azure run passes the manifest validator;
- the report references that approved run and is no longer marked draft;
- final PNGs faithfully match the approved contracts and pass visual QA;
- all repository quality gates pass;
- the disposable validation lab and exact probe identities are removed;
- the validated working tree is ready for a repository-owner commit;
- commit and repository sync are performed only when explicitly requested and a Git remote is
  configured.
