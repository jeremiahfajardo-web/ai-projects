# Feature: Compliance Platform — Core Release & Distribution

## Status
[ ] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-29 — **PARKED stub, not yet scheduled.** Created to hold the
forward-dependency surfaced by
[compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md):
how Core is delivered to client deployments and how its integrity is verifiable. No decision
is made here yet — this captures the problem and the open questions so the boundary spec links
to a real doc. Required before customer #1; do not build until scoped._

## Problem Statement
The Pack model (see the boundary spec) ships **one shared, versioned Core** to many isolated
single-tenant client deployments. That only works if there is a defined way to **deliver Core to
a client box**, **verify it is the unmodified published build**, and **deliver upgrades** so a
Core fix reaches everyone. The boundary spec asserts "Core ships as a sealed, versioned image
that self-reports its digest" as the integrity mechanism — but the actual distribution/build
pipeline behind that assertion is unspecced. Without it, the integrity and upgrade-delivery
promises in the boundary spec are assumptions, not capabilities.

## Acceptance Criteria
_Draft — to be firmed once the distribution model is chosen (see Open Questions)._
- [ ] Core is delivered as a **sealed, versioned artifact** (leading candidate: a container
      image), not as source a client edits in place.
- [ ] The running Core **self-reports its version + image digest at boot** (extends the
      config-self-check guard); a deployment can be checked against the published baseline.
- [ ] A **published-digest baseline** exists somewhere authoritative, and a mismatch is
      surfaced on upgrade/support.
- [ ] An **upgrade path** delivers a new Core build to a deployed Instance and interacts
      correctly with the Pack `requires_core` compatibility gate.
- [ ] The mechanism works for the stack's **local-first** posture (no mandatory cloud; consider
      air-gapped / offline clients).

## Affected Repos / Surfaces
- **ai-infrastructure-v1** — image build, tagging, and the compose/registry wiring that a client
  deployment pulls from; where a `packs/` bundle + Instance config mount alongside the image.
- **ai-mcp-server-v1 / ai-rag-llm-client-v1** — the boot-time digest/version self-report
  (extends the existing config-self-check pattern).
- **ai-projects** (this repo) — this spec; pairs with the boundary spec's integrity criterion.

## Inputs
_TBD — parked until the distribution model is chosen._

## Outputs / Response Shape
_TBD — likely a boot/health surface exposing `{ core_version, image_digest, baseline_match }`._

## Data Flow
_TBD — parked. Sketch once a mechanism is chosen (build → publish → client pull/verify → run →
upgrade)._

## Schema Impact
None expected — distribution/build concern, not a data concern. Confirm when scoped.

## Seams & Forward-Compatibility
- Builds directly on the boundary spec's **"Core integrity is detectable"** acceptance criterion
  and its **sealed-image distribution** forward-dependency.
- The boot-time **config-self-check** guard already exists as the seam for the digest/version
  self-report — this spec extends it rather than inventing a new mechanism.
- Pairs with the Pack **`requires_core`** version gate for upgrade compatibility.

## Edge Cases & Error Handling
_TBD — parked. At minimum: digest mismatch (tampered/unsupported build), failed/partial upgrade,
offline client unable to reach a registry, downgrade attempts._

## Security Review
_Not yet filled — parked stub at `[ ] Spec`. Must be completed against
[docs/security-checklist.md](../security-checklist.md) before this advances past Spec. Headline
items it will own: **A08 Software & Data Integrity Failures** (the whole point — verified,
unmodified Core builds) and **LLM03 Supply Chain** (image provenance/signing)._

## Out of Scope for This Feature
- The Core/Pack/Instance boundary itself (the parent
  [boundary spec](compliance-platform-core-pack-boundary.md)).
- Pack bundle distribution (declarative config; redeploy of the bundle, not the engine image).
- Any concrete compliance engine build.

## Test Plan
_TBD — parked until scoped._

## Smoke Test (user-performed, on the running stack)
_TBD — parked. Will verify a published image's boot-time digest matches the baseline, and that an
upgrade replaces an in-place-modified Core (digest returns to published)._
- **Result**: _pending — parked stub._

## Open Questions
- [ ] **Distribution mechanism.** Private container registry pull vs. exported image tarball vs.
      an installer/bundle. Which fits how private/on-prem clients actually want to receive
      software? (User has not yet been exposed to these expectations — research before deciding.)
- [ ] **Published-digest baseline location.** Where the authoritative "known-good" digest lives
      and how a client/our support checks against it.
- [ ] **Upgrade delivery.** Pull (client-initiated) vs. push; how it interacts with
      `requires_core`; whether upgrades can be automatic or are always operator-driven.
- [ ] **Offline / air-gapped clients.** Whether the local-first pitch requires delivery that
      needs no outbound network at all.
- [ ] **Image signing / provenance** (supply chain — LLM03/A08): do we sign images, and does the
      client verify a signature in addition to the digest?
- [ ] **Licensing / support-boundary tie-in.** Cross-references the boundary spec's
      support/warranty Open Question (support covers only the unmodified published digest).
