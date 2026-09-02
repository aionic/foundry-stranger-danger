# Architecture figures and contracts

These Mermaid files are the authoritative semantic contracts for the customer-facing figures.
They separate five viewpoints so that deployment, security behavior, target architecture,
operations, and evidence lineage are not mixed in one diagram.

| Source | Final PNG | Viewpoint |
|---|---|---|
| [`validation-lab-topology.mmd`](validation-lab-topology.mmd) | [Validation lab topology](rendered/validation-lab-topology-azure-architecture.png) | What the validation repository deploys |
| [`measured-authorization-boundary.mmd`](measured-authorization-boundary.mmd) | [Measured authorization boundary](rendered/measured-authorization-boundary-azure-architecture.png) | What each tested permission shape can reach |
| [`recommended-customer-target-state.mmd`](recommended-customer-target-state.mmd) | [Recommended customer target state](rendered/recommended-customer-target-state-azure-architecture.png) | Recommended design for separate trust boundaries |
| [`bootstrap-harden-verify-sequence.mmd`](bootstrap-harden-verify-sequence.mmd) | [Bootstrap, harden, and verify](rendered/bootstrap-harden-verify-sequence-azure-architecture.png) | Safe shared-store deployment sequence |
| [`test-controls-and-evidence.mmd`](test-controls-and-evidence.mmd) | [Test controls and evidence lineage](rendered/test-controls-and-evidence-azure-architecture.png) | Controls and evidence lineage |

## Status

All five contracts passed Mermaid CLI 11.16.0 validation and were explicitly approved on
3 September 2026. The approval is locked in [`approved-contract-lock.json`](approved-contract-lock.json).

The final 3840 x 2160 PNGs use unmodified official Microsoft Azure Public Service Icons V24. Every
PNG passed source-lock, icon-hash, output-hash, dimension, nonblank-pixel, semantic-inventory, and
visual QA. No clipping, overlap, ambiguous arrow direction, or unreadable label remains. Rendering
changed geometry and presentation only; it did not change contract semantics.

Any subsequent semantic edit to an `.mmd` file invalidates the approval hash and reopens review.

The completed review confirmed:

- the validation lab is not presented as the production target state;
- broad and project-constrained permission shapes are distinguishable;
- each component, edge direction, boundary, and result matches the assessment;
- Search remains identified as a shared lab condition and a separate-service recommendation;
- final rendering is understood to change presentation only.

## Reproduce validation and rendering

Run the pinned local validator:

```powershell
npm install
npm run diagrams:validate
npm run diagrams:render
.\scripts\Test-RenderedDiagrams.ps1
```

If npm did not install a browser and no compatible Chromium browser is available, run
`npm run diagrams:browser` once, then repeat validation.

The renderer refuses any source whose SHA-256 differs from the approval lock. It writes
[`render-manifest.json`](rendered/render-manifest.json) with source, renderer, icon, and output
hashes plus dimensions and pixel checks. Official Azure icons are used only for Azure services;
projects, identities, probes, controls, and conceptual boundaries use generic shapes.
