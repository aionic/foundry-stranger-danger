# Findings

The detailed findings now have one authoritative home: the
[Microsoft Foundry cross-project data isolation assessment](00-report.md).

The headings below preserve links from earlier versions of this document.

## F1 — Cosmos grant spans all projects in the documented configuration

See [F1: shared-database Cosmos scope](00-report.md#f1-shared-database-cosmos-scope-expands-the-project-credential-boundary).

## F2 — Documented blob container names are wrong, and bad grants fail silently

See [F2: constructed Blob container scopes](00-report.md#f2-constructed-blob-container-scopes-can-be-silently-ineffective).

## F3 — Connection names are account-scoped despite a project-scoped path

See [Operational observations](00-report.md#operational-observations), item O1.

## F4 — The account serialises operations against itself

See [Operational observations](00-report.md#operational-observations), item O2.

## F5 — Container inventory

See [Architecture: data ownership](01-architecture.md#data-ownership) and
[Assessment scope](00-report.md#scope).

## F6 — AI Search: service-scoped grants span all projects, and indexes are not attributable

See [F3: shared Search](00-report.md#f3-shared-search-is-not-a-durable-foundry-project-boundary-for-vector-data).

## Validity of the test

See [Assurance statement](00-report.md#assurance-statement) and
[Validation runbook](03-validation-runbook.md).

## Limitations

See [Assessment limitations](00-report.md#limitations).
