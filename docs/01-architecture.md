# Architecture

This document separates the **validation lab**, the **measured authorization boundary**, and the
**recommended customer target state**. They answer different questions and must not be presented as
one architecture.

The default multi-project boundary examined here is programmatic: Foundry uses project context,
generated names, and runtime routing to select each project's data. The lab bypasses that normal
path and asks whether Cosmos DB, Storage, and AI Search also enforce the same boundary through
authorization.

## Architecture interpretation

- A Foundry account is the top-level governance resource; projects are development boundaries within
  it.
- Foundry's normal project routing and a backing service's authorization decision are separate
  controls.
- Cosmos DB, Storage, and AI Search are connected Azure resources with their own authorization and
  network controls.
- The lab deliberately connects two projects to one instance of each backing service so
  cross-project authorization can be measured.
- Each project has its own system-assigned managed identity and project-prefixed Cosmos/Blob
  resources.
- A resource name is an ownership signal, not an authorization boundary.
- Modern Responses API agents create two Cosmos containers lazily on first invocation.
- Cosmos and Storage can express durable project constraints once their resources are discoverable.
- Shared-service project identities retain provisioning roles with service-wide management actions;
  the constrained read results are not a hostile-identity boundary.
- The tested Foundry vector-store interface did not expose a durable project-to-index mapping.
- Projects in separate customer, tenant, ownership, or sensitivity domains require separate backing
  resources.
- Production private networking, availability, backup, and disaster recovery are outside the lab's
  measured scope.

## View 1: validation lab

![Validation lab with two Foundry projects intentionally sharing Cosmos DB, Storage, and AI Search while diagnostics collect evidence.](diagrams/rendered/validation-lab-topology-azure-architecture.png)

*Figure 1. Validation lab topology. [Approved Mermaid contract](diagrams/validation-lab-topology.mmd).*

The lab deploys one Foundry account with two projects and intentionally shared data services. Its
purpose is to compare permission shapes, not to recommend shared services for every production
workload.

| Component | Responsibility in the lab |
|---|---|
| Foundry account | Shared governance scope and model deployment |
| Project `alpha` / `bravo` | Separate agent endpoint, identity, capability host, and connections |
| Cosmos DB | Shared `enterprise_memory` database containing project-prefixed state containers |
| Storage | Shared account containing project-prefixed Blob containers |
| AI Search | Shared service containing one generated index per test vector store |
| Application Insights / Log Analytics | Platform telemetry and data-plane diagnostic evidence |
| Key Vault | Reference dependency deployed by the lab; not on the measured agent data path |
| Probe identities | Surrogate read principals used to exercise specific authorization shapes |

### Data ownership

| Data | Authoritative owner | Lab location | Attribution |
|---|---|---|---|
| Agent definitions and run state | Foundry project | Project-prefixed Cosmos containers | Dashed project GUID prefix |
| Classic thread/message state | Foundry project | Project-prefixed Cosmos containers | Dashed project GUID prefix |
| Agent files | Foundry project | Project-prefixed Blob containers | Dashed project GUID prefix; one service-assigned suffix |
| Vector index | Foundry vector store | Shared Search service | Ownership observed by serialized create-and-diff only |
| Probe result | Validation run | Manifest-bound JSON artifacts | Run ID and SHA-256 hashes |

The Foundry project is the owner of its logical assets. The connected Azure resource remains the
authorization enforcement point for the backing data.

## View 2: measured authorization boundary

![Measured direct data-plane authorization showing broad cross-project reach and constrained own-project access for Cosmos DB, Storage, and AI Search.](diagrams/rendered/measured-authorization-boundary-azure-architecture.png)

*Figure 2. Measured authorization behavior. [Approved Mermaid contract](diagrams/measured-authorization-boundary.mmd).*

The lab measures initiating access from an identity to a backing-service resource. It does not imply
that the Foundry runtime normally routes one project's request to another project's data.

This view covers direct data-plane requests. It does not model a compromised project identity using
its retained Storage Account Contributor, Search Service Contributor, or Cosmos DB Operator
permissions. The first two expose broad management actions on the shared services; separate resource
sets are required when identities are not mutually trusted.

| Store | Broad shape | Project-constrained shape | Measured result |
|---|---|---|---|
| Cosmos DB | Role at shared database | Five roles at owned containers | Broad reached both projects; constrained denied the other project |
| Storage | Unconditioned account role used as connectivity control | Account role with project-prefix condition | Broad reached both projects; conditioned denied the other project |
| AI Search | Service role | Single-index role | Service role reached both indexes; index role denied the other index |

Three boundaries must remain distinct:

1. **Storage layout:** whether projects receive different containers or indexes.
2. **Authorization:** which resources the identity's grants include.
3. **Enforcement:** whether an attempted access outside the intended project is denied.

Separate storage layout without constrained authorization is not defense in depth. Conversely, a
`DENY` without a successful own-project control may only prove that the test path is broken.

## View 3: recommended customer target state

![Recommended target state with distinct Cosmos DB, Storage, and AI Search services for alpha and bravo trust boundaries.](diagrams/rendered/recommended-customer-target-state-azure-architecture.png)

*Figure 3. Recommended customer target state. [Approved Mermaid contract](diagrams/recommended-customer-target-state.mmd).*

The default recommendation for distinct trust boundaries is:

- retain centralized Foundry governance and approved model deployments where organizational policy
  permits;
- assign one managed identity per project;
- give each project its own Cosmos DB account, Storage account, and AI Search service;
- apply local-auth disablement, private networking, diagnostics, policy, and lifecycle controls to
  each connected resource;
- permit only the owning project's identity on each backing service.

This design spends more resources to make the ownership and failure boundary explicit. It removes
the shared-Cosmos bootstrap exposure and avoids relying on generated Search index attribution.

Shared hardened Cosmos and Storage remain an available optimization only when projects are already
inside one accepted trust boundary. Shared Search is not recommended where vector data needs strict
project isolation.

## Architecture decisions

### A1. Separate backing services across trust boundaries

**Decision**

Use one Cosmos DB, Storage, and AI Search resource set per project when projects represent separate
customers, tenants, owners, or sensitivity classes.

**Why**

The service boundary then matches the data boundary, and service-scoped permissions cannot span
projects. It also contains persistent provisioning permissions within the owning project's resource
set.

**Tradeoff**

Higher resource count, baseline cost, policy surface, and operational overhead.

**Validation status**

**Recommended.** The lab measured why shared-service scope matters; it did not deploy this target
state.

### A2. Harden shared Cosmos with a two-phase process

**Decision**

Within one trust boundary, use temporary database scope only for bootstrap, then replace it with five
container grants per project before handover.

**Why**

Two modern containers do not exist until the first Responses API invocation, and Cosmos rejects a
role assignment to an absent container.

**Tradeoff**

Creates a bounded bootstrap window and a procedural dependency. Failed verification must leave the
project unavailable for real use.

**Validation status**

**Measured and automated** by `scripts/deploy-and-harden.ps1` for the lab topology.

### A3. Constrain shared Storage with ABAC

**Decision**

Assign the Blob data role at account scope with a condition matching the project's dashed GUID
container prefix.

**Why**

One observed container includes an unpredictable service-assigned segment, and assignments to
absent Blob containers can appear successful.

**Tradeoff**

Conditions require careful action coverage, review, and regression testing.

**Validation status**

**Measured and automated** for read controls; project configuration is also asserted.

### A4. Split Search for strict vector isolation

**Decision**

Use one AI Search service per project when vector stores or file search cross trust boundaries.

**Why**

Single-index RBAC is enforced, but the tested Foundry interface did not expose the generated index
name or a durable ownership mapping.

**Tradeoff**

Additional Search services and capacity management.

**Validation status**

Shared-service and single-index read scopes are **measured**. One Search service per project is
**recommended** but deliberately not deployed by this lab; the shared service-scoped project roles
remain in place so the programmatic Search boundary can be measured.

### A5. Verify configuration and behavior independently

**Decision**

Require both actual project-grant assertions and positive/negative data-plane probes.

**Why**

Surrogate probes do not reveal current project identity grants, while configuration inspection alone
does not prove enforcement.

**Tradeoff**

More validation steps and evidence artifacts.

**Validation status**

**Implemented** in the evidence contract and covered by sanitized offline tests.

## Primary deployment and validation flow

![Sequence for deploying a project, granting temporary bootstrap access, creating lazy containers, tightening scopes, and failing closed unless configuration and behavior checks pass.](diagrams/rendered/bootstrap-harden-verify-sequence-azure-architecture.png)

*Figure 4. Bootstrap, harden, and verify sequence. [Approved Mermaid contract](diagrams/bootstrap-harden-verify-sequence.mmd).*

1. Deploy the Foundry account, projects, identities, model, and connected resources.
2. Create project connections and provisioning roles.
3. For shared Cosmos, grant temporary database data access while no users or real workloads exist.
4. Apply the project-prefix Storage condition.
5. Invoke one synthetic canary agent per project through Responses API `v1`.
6. Confirm all five Cosmos and two Blob containers per project are attributable.
7. Add five Cosmos container grants per project and remove the temporary database grants.
8. Assert the real project identities' Cosmos and Storage configuration.
9. Require own-project `ALLOW` and cross-project `DENY` for Cosmos and Blob.
10. Test Search separately and record the exact indexes used.
11. Archive and hash the run; fail closed on any mismatch, block, or error.
12. Remove synthetic data, then grant users or applications access.

## Well-Architected review

**Reliability:** The lab uses single service instances. Foundry, Cosmos, and Storage ran in
`westus3`; Search ran in `eastus` because of capacity. The lab does not establish an availability
SLO, RTO, RPO, backup, regional-resiliency, or failover design. Production architecture must add
these from business requirements rather than copy the lab.

**Security:** Identity-based access and disabled local keys are strengths. Separate resource sets are
the clearest trust boundary. Shared-resource designs depend on exact role scope, bootstrap control,
private networking, diagnostics, and fail-closed verification. Direct data-plane constraints do not
remove the management authority of retained provisioning roles.

**Cost optimization:** Sharing reduces resource count but couples trust, capacity, and operational
risk. Separate Search is a justified cost where vector data crosses trust boundaries. Separate all
backing services only where the stronger boundary is required.

**Operational excellence:** Terraform, deterministic evidence artifacts, source hashes, offline
contract tests, and teardown automation provide traceability. Production use still needs CI,
approvals, alerting, incident ownership, and periodic access recertification.

**Performance efficiency:** The lab is not a load test. Cosmos throughput, Search capacity, model
quota, cross-region latency, and concurrent project growth require workload-specific validation.

## Architecture review notes

- The diagrams intentionally omit production private endpoints, DNS, firewalls, zones, regions, and
  disaster recovery because those were not measured.
- Key Vault is deployed but is not a data-path dependency in this test.
- Search object-management permissions can have broader implications than direct single-index query
  permissions and must be separated from application data roles.
- The shared-service option assumes all participating projects have the same data residency,
  retention, support, and incident-response requirements.
- Final PNGs are blocked until the five Mermaid contracts pass human semantic review.

**Architecture status: rendered from the human-approved Mermaid contracts. No semantic changes were introduced during rendering.**
