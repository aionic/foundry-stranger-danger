# Microsoft Foundry project isolation: deploy, harden, verify

This repository shows where the security boundary actually sits when two Microsoft Foundry
projects share Azure Cosmos DB, Azure Storage, and Azure AI Search. It is a disposable validation
lab and evidence harness, not a production reference deployment.

> [!IMPORTANT]
> A Foundry project creates a distinct identity and project-prefixed data layout. Neither the
> project nor the resource name is an authorization boundary by itself. The enforceable boundary
> comes from the backing-resource topology and the scope of the Azure and Cosmos role assignments.

## The short answer

| Question | Answer |
|---|---|
| What does the lab deploy? | One Foundry account, two projects, and one shared instance each of Cosmos DB, Storage, and AI Search |
| Is a clean deployment isolated? | No. Shared Cosmos needs a temporary database-scoped bootstrap grant, and Search remains service-scoped |
| What does the hardening script enforce? | Direct Cosmos and Blob data-plane access is limited to each project's own containers and verified with positive and negative controls |
| Is the hardened lab a hard trust boundary? | No. Project identities retain management roles on shared services, and Search is intentionally shared |
| What is the sane production boundary? | For separate customers, tenants, owners, or sensitivity classes, use a separate Cosmos account, Storage account, and Search service per project |

Accepted evidence run:
[`20260903T220650154Z-14a2c4a0`](evidence/published/20260903T220650154Z-14a2c4a0/REPORT.md).

## Platform behavior versus lab configuration

Keep these three layers separate:

1. **Foundry creates** a project identity, endpoint, capability host, connections, and
   project-prefixed Cosmos and Blob containers.
2. **This repository configures** two projects to use the same backing services and assigns the
   roles needed to measure cross-project access.
3. **You choose** whether the production boundary is a narrow role scope inside one trusted shared
   service or a separate backing resource for each trust boundary.

The broad Cosmos bootstrap role in this lab is a tested permission shape. Do not describe it as an
automatic platform default without confirming the current deployment template you use.

## What a default lab deployment looks like

![Validation lab with two Foundry projects intentionally sharing Cosmos DB, Storage, and AI Search while diagnostics collect evidence.](docs/diagrams/rendered/validation-lab-topology-azure-architecture.png)

Each project has its own system-assigned managed identity, but both identities receive permissions
on the same backing resources.

| Store | Bootstrap data access | Verified lab end state | Retained management access |
|---|---|---|---|
| Cosmos DB | `Cosmos DB Built-in Data Contributor` on the shared `enterprise_memory` database | Five container-scoped data assignments per project; no project database- or account-scoped data assignment | `Cosmos DB Operator` on the shared account |
| Storage | `Storage Blob Data Owner` at account scope with an ABAC condition matching the project's dashed GUID container prefix | The same conditioned assignment; own-prefix reads allowed and the other project denied | `Storage Account Contributor` on the shared account |
| AI Search | `Search Index Data Contributor` and `Search Service Contributor` at service scope | Unchanged by the hardening script; both projects can reach the shared service | Service-wide object management remains available |

The lab also grants the deployer broad read access and can create surrogate probe identities. Those
controls prove that resources exist and that a denial is an authorization result rather than an
empty resource. Their credentials are stored in local Terraform state.

Cosmos, Storage, and Search local key authentication is disabled. Public data endpoints remain
enabled intentionally so the lab can distinguish an RBAC denial from a network refusal. Production
private networking is outside this assessment.

## The clean-deployment bootstrap window

Two defaults are easy to confuse:

- Terraform's `isolation_mode` defaults to `hardened`, which describes the required steady state.
- A clean environment cannot be created directly in that state. The guard in
  [terraform/guardrails.tf](terraform/guardrails.tf) blocks it and directs operators to the
  orchestrator.

The capability host initially creates three Cosmos containers per project. These two additional
containers appear only after the first Responses API invocation:

```text
<project-guid>-agent-definitions-v1
<project-guid>-run-state-v1
```

Cosmos rejects a role assignment scoped to a container that does not exist. The supported clean
deployment therefore starts with database-scoped access, writes only a synthetic canary, discovers
all five containers, and then replaces the broad role. Precreating service-owned containers is not
recommended because their indexing policy belongs to the service and may change.

> [!WARNING]
> During bootstrap, either project identity can address the other project's Cosmos containers.
> Do not assign users or applications and do not introduce real data until hardening and
> verification succeed.

## Deployment lifecycle

The supported entry point is [scripts/deploy-and-harden.ps1](scripts/deploy-and-harden.ps1), not a
plain `terraform apply` on a clean environment.

| Phase | Action | Security state |
|---|---|---|
| 0. Preflight | Check tools, Azure access, providers, model quota, and configuration | Nothing is declared usable |
| 1. Bootstrap | Deploy shared services and projects with database-scoped Cosmos access | Bootstrap window open; synthetic data only |
| 2. Canary | Invoke one Responses API `v1` agent per project | Lazy containers are created |
| 3. Discover | Require all five Cosmos containers per project to exist | Hardening can now target real resources |
| 4. Harden | Replace each database grant with five project-container grants | Broad project Cosmos data grants removed |
| 5. Verify | Inspect real roles and run own-project/cross-project Cosmos and Blob reads | Fail closed unless every expected result matches |

Search is not hardened in phase 4. It stays shared so the Search exposure can be reproduced by the
evidence collector.

## Choose the boundary before deploying

| Project relationship | Cosmos DB | Storage | AI Search | Meaning |
|---|---|---|---|---|
| Separate customer, tenant, owner, sensitivity, residency, or incident boundary | Per project | Per project | Per project | Hard resource and RBAC boundary |
| One accepted trust boundary; vector stores or file search used | Shared with container roles | Shared with project-prefix ABAC | Per project | Direct shared-data access constrained; vector data separated |
| One accepted trust boundary; no vector data requiring strict isolation | Shared with container roles | Shared with project-prefix ABAC | Shared only by explicit risk acceptance | Cost optimization inside one trust boundary |
| Bootstrap cannot be completed before user access | Per project | Prefer per project | Per project when used | Avoids the shared-Cosmos bootstrap window |

### Same-trust RBAC boundary

Shared Cosmos and Storage can provide a useful direct data-plane boundary when all projects already
belong to one operational and security trust domain:

- Cosmos data access is scoped to the five owned containers.
- Blob data access is conditioned on the owning project's container-name prefix.
- Configuration assertions and live reads verify both own-project access and cross-project denial.

This is the boundary automated by this repository.

### Cross-trust hard boundary

For mutually untrusted projects, use one backing-resource set per project and grant each project
identity roles only on its own set. A centralized Foundry account and approved model deployments may
still be retained where policy permits, but the project identity must have no data or management
role on another project's Cosmos account, Storage account, or Search service.

This removes the shared-Cosmos bootstrap exposure and contains persistent provisioning authority.
The architecture is recommended here but is not deployed by this repository.

## Run the validation lab

Use a disposable subscription or isolated test resource group. The lab creates broad controls,
stores temporary service-principal secrets in Terraform state, and intentionally uses public data
endpoints.

Prerequisites are PowerShell 7, Azure CLI, Terraform 1.9 or later, permission to create role
assignments and Entra app registrations, and quota for the selected model.

```powershell
.\scripts\00b-find-search-region.ps1

Copy-Item .\terraform\terraform.tfvars.example .\terraform\terraform.tfvars
# Edit subscription_id, location, search_location, owner, and required tags.

terraform -chdir=terraform init
.\scripts\deploy-and-harden.ps1
```

The orchestrator runs preflight, opens and closes the bounded Cosmos bootstrap window, and verifies
Cosmos and Storage. A successful exit does not certify shared Search.

The canary data remains after the script succeeds. Remove it before assigning real users or
applications.

## What verification requires

Configuration and behavior are independent gates. Both must pass.

**Configuration**

- Exactly five container-scoped Cosmos data assignments exist for each project identity.
- No project identity retains a Cosmos data assignment at database or account scope.
- Exactly one account-scoped, conditioned `Storage Blob Data Owner` assignment exists per project.
- No unconditioned account-scoped Blob data role remains on a project identity.
- Every expected container is attributable to its project.

**Behavior**

| Probe | Alpha Cosmos | Alpha Blob | Bravo Cosmos | Bravo Blob |
|---|---|---|---|---|
| Broad connectivity control | `ALLOW` | `ALLOW` | `ALLOW` | `ALLOW` |
| Alpha-scoped | `ALLOW` | `ALLOW` | `DENY` | `DENY` |
| Bravo-scoped | `DENY` | `DENY` | `ALLOW` | `ALLOW` |

That is twelve required outcomes: $3$ probes x $2$ projects x $2$ stores. An own-project denial,
unexpected error, or `BLOCKED` network result invalidates the run. A firewall refusal is defense in
depth, not proof that RBAC denied the request.

Rerun verification against an existing deployment with:

```powershell
.\scripts\deploy-and-harden.ps1 -VerifyOnly
```

## Harden an existing environment in a sane order

1. Classify each project's customer, owner, sensitivity, residency, retention, and incident
   boundary.
2. Split Cosmos, Storage, and Search first when any of those trust properties differ.
3. If Cosmos remains shared, add all five project-container data assignments before removing the
   database-scoped assignment.
4. If Storage remains shared, replace unconditioned Blob data roles with a tested project-prefix
   ABAC condition. Validate against the actual generated container names.
5. Give each project its own Search service wherever vector stores or file search cross a trust
   boundary.
6. Disable local and shared-key authorization so identity policy cannot be bypassed.
7. Verify the real project role inventory and run positive and negative data-plane controls.
8. Preserve the configuration and probe evidence together, remove synthetic data, and only then
   grant workload access.

Use the [hardening guide](docs/05-hardening-guide.md) for audit commands, exact assignment shapes,
failure recovery, and the completion checklist.

## What a successful lab run does and does not prove

| Claim | Supported? |
|---|---|
| Each project identity can directly read its own Cosmos and Blob resources | Yes |
| Each scoped probe is denied direct reads against the other project's Cosmos and Blob resources | Yes |
| Shared Search is project-isolated | No; the lab intentionally leaves service-scoped Search access |
| A compromised project identity cannot affect another project | No; shared-service management roles remain |
| Project-prefixed names alone enforce authorization | No |
| Production private networking, availability, backup, or disaster recovery is validated | No |

The important distinction is between a **direct data-plane RBAC boundary inside one trust domain**
and a **hard boundary against a hostile or compromised project identity**. The latter requires
separate backing resources and the absence of cross-project management roles.

## Collect evidence and tear down

After the orchestrator succeeds, collect a manifest-bound run:

```powershell
.\scripts\12-collect-evidence.ps1 -SkipAgents
```

Generated evidence is written under `evidence/runs/<run-id>-<mode>/` with source hashes, artifact
hashes, configuration assertions, and an offline validation result. Raw evidence is gitignored.

Destroy the disposable environment when finished:

```powershell
.\scripts\99-destroy.ps1
```

## Read by outcome

| Goal | Document |
|---|---|
| Make the security or architecture decision | [Customer assessment](docs/00-report.md) |
| Compare the lab with the recommended target state | [Architecture](docs/01-architecture.md) |
| Reproduce and interpret the measurements | [Validation runbook](docs/03-validation-runbook.md) |
| Audit and remediate an environment | [Hardening guide](docs/05-hardening-guide.md) |
| Review the approved architecture figures | [Architecture figures](docs/diagrams/README.md) |
| Understand evidence provenance and publication | [Evidence guide](evidence/README.md) |

## Scope and limitations

- Modern Foundry Agents using the Responses API (`api-version=v1`) were tested.
- Two projects and one Foundry account were measured; this is not a scale, performance,
  availability, regional-resiliency, or failover assessment.
- Public endpoints were used to isolate authorization behavior. Production networking was not
  assessed.
- Project managed identities cannot be impersonated. Surrogate principals exercise equivalent
  permission shapes while separate assertions inspect the real project identities.
- Persistent provisioning roles were inventoried, but management-plane attack paths were not
  exercised.

## Current Microsoft references

Sources were reviewed on **2 September 2026**:

- [Use your own resources in Foundry Agent Service](https://learn.microsoft.com/en-us/azure/foundry/agents/how-to/use-your-own-resources)
- [Microsoft Foundry architecture](https://learn.microsoft.com/en-us/azure/foundry/concepts/architecture)
- [Azure Cosmos DB data-plane RBAC](https://learn.microsoft.com/en-us/azure/cosmos-db/how-to-connect-role-based-access-control)
- [Azure AI Search RBAC](https://learn.microsoft.com/en-us/azure/search/search-security-rbac)
- [Azure Storage ABAC](https://learn.microsoft.com/en-us/azure/storage/blobs/storage-auth-abac)

## Repository contents

| Path | Purpose |
|---|---|
| [terraform/](terraform) | Reproducible validation topology and permission shapes |
| [scripts/](scripts) | Preflight, deployment, probes, evidence packaging, and teardown |
| [docs/](docs) | Customer assessment, architecture, runbook, and hardening guidance |
| [docs/diagrams/](docs/diagrams) | Authoritative Mermaid architecture contracts |
| [evidence/](evidence) | Generated evidence layout and tracked publication guidance |

## License

[MIT](LICENSE)
