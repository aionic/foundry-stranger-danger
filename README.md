# Microsoft Foundry cross-project data isolation

This repository measures how two Microsoft Foundry projects behave when they share Azure
Cosmos DB, Azure Storage, and Azure AI Search. It is an **evidence harness**, not a production
reference deployment.

## Executive answer

**Microsoft Foundry creates separate project data resources, and Azure authorization enforces
narrow scopes when those scopes are applied. The effective security boundary therefore depends
on the backing-resource topology and role-assignment scope.**

| Store | Measured result | Required customer action |
|---|---|---|
| Cosmos DB | A database-scoped grant reached both projects; container-scoped grants denied cross-project reads | Treat database scope as temporary bootstrap access and replace it with five container grants per project |
| Storage | A project-prefix ABAC condition constrained direct Blob data-plane reads. The project also retains broad provisioning permissions in this lab. | Use a conditioned account assignment only within one trust boundary; use separate accounts across trust boundaries |
| AI Search | Service scope reached both project indexes; index scope was enforced, but Foundry index names did not identify their project | Use one Search service per project when vector stores or file search require a hard boundary |

The hardened Cosmos and Storage matrix contains twelve outcomes: $3$ probes × $2$ projects ×
$2$ stores. All twelve must match, including own-project `ALLOW` controls. A firewall refusal,
unexpected status, or own-project denial invalidates the run.

Accepted evidence run: [`20260903T220650154Z-14a2c4a0`](evidence/published/20260903T220650154Z-14a2c4a0/REPORT.md).

The probes test **direct data-plane authorization**. They do not prove a hard boundary against
compromise of a project identity that retains broad management roles needed by the shared-service
lab. Storage Account Contributor and Search Service Contributor apply across their shared services.
This is why separate backing resources, not ABAC alone, are required across trust boundaries.

## Decide what to do

| Your situation | Direction |
|---|---|
| Projects represent separate customers, tenants, owners, or sensitivity classes | Use separate Cosmos DB, Storage, and AI Search resources per project |
| Projects share one trust boundary and do not use vector stores or file search | Shared Cosmos and Storage can be retained with container and ABAC hardening |
| Projects share one trust boundary and use vector stores or file search | Shared hardened Cosmos and Storage may be retained; use a separate Search service per project |
| You cannot complete and verify two-phase bootstrap before user access | Use separate data resources per project so temporary shared-database access is unnecessary |

Start with the [hardening guide](docs/05-hardening-guide.md) to audit an existing environment.


## Read by outcome

| Goal | Document |
|---|---|
| Make a risk or architecture decision | [Customer assessment](docs/00-report.md) |
| Understand the validation lab and recommended target state | [Architecture](docs/01-architecture.md) |
| Reproduce the measurements | [Validation runbook](docs/03-validation-runbook.md) |
| Audit and remediate an environment | [Hardening guide](docs/05-hardening-guide.md) |
| View the approved customer architecture figures | [Architecture figures](docs/diagrams/README.md) |
| Understand generated evidence and provenance | [Evidence guide](evidence/README.md) |

The former isolation-model and findings documents remain as compatibility pointers; their unique
content is consolidated into the four documents above.

## Run the validation lab

Use a disposable subscription. The lab intentionally creates broad control grants, generates
service-principal secrets in local Terraform state, and uses public data endpoints so probes can
exercise RBAC directly.

```powershell
.\scripts\00b-find-search-region.ps1

Copy-Item .\terraform\terraform.tfvars.example .\terraform\terraform.tfvars
# Edit the subscription, Foundry region, Search region, and owner.
terraform -chdir=terraform init

# Includes preflight using the effective Terraform model and region.
.\scripts\deploy-and-harden.ps1
.\scripts\12-collect-evidence.ps1 -SkipAgents
```

`deploy-and-harden.ps1` verifies **Cosmos and Storage**. AI Search remains shared in this lab by
design so the Search finding can be reproduced; the evidence collector runs that test separately.
Do not interpret the script's success as approval of shared Search for production.

Generated evidence is placed under `evidence/runs/<run-id>-<mode>/` with a manifest, source hashes,
artifact hashes, and an offline validation result. Raw evidence is intentionally gitignored.

Tear down when finished:

```powershell
.\scripts\99-destroy.ps1
```

## Scope and limitations

- Modern Foundry Agents using the Responses API (`api-version=v1`) were tested.
- Two projects and one Foundry account were measured. Foundry, Cosmos, and Storage ran in
   `westus3`; Search ran in `eastus` because of capacity. This is not a scale, performance,
   availability, regional-resiliency, or failover assessment.
- Public endpoint behavior was used to isolate authorization testing. Production network design
   was not assessed.
- Persistent project provisioning roles were inventoried but privilege-escalation paths through
   management operations were not exercised. Shared-service hardening is not a hostile-identity
   boundary.
- Project managed identities cannot be impersonated. Surrogate service principals exercised the
   same permission shapes, while configuration assertions checked the real project identities.
- Current raw snapshots in a developer workspace are historical inputs until regenerated by the
   manifest-based collector; they are not distributed as customer evidence.

## Current Microsoft references

Sources were reviewed on **2 September 2026**:

- [Use your own resources in Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/use-your-own-resources) documents project-prefixed Cosmos containers and the two containers created on first Responses API invocation.
- [Microsoft Foundry architecture](https://learn.microsoft.com/en-us/azure/foundry/concepts/architecture) distinguishes project assets from connected Azure resources, whose networking and access policies are governed separately.
- [Azure Cosmos DB data-plane RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-connect-role-based-access-control) documents account, database, and container assignment scopes.
- [Azure AI Search RBAC](https://learn.microsoft.com/en-us/azure/search/search-security-rbac) documents service and single-index role assignments and recommends separate services where strict index isolation is required.
- [Azure Storage ABAC](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-auth-abac) documents resource-attribute conditions on Blob data roles.

## Repository contents

| Path | Purpose |
|---|---|
| [terraform/](terraform) | Reproducible validation topology and permission shapes |
| [scripts/](scripts) | Preflight, deployment, probes, evidence packaging, and teardown |
| [docs/](docs) | Customer assessment, architecture, runbook, and hardening guidance |
| [docs/diagrams/](docs/diagrams) | Authoritative Mermaid architecture contracts |
| [evidence/](evidence) | Local generated evidence plus the tracked evidence guide |

## Licence

[MIT](LICENSE)
