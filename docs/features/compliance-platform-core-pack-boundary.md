# Feature: Compliance Platform — Core / Pack / Instance boundary

## Status
[ ] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-26 — initial draft + first round of resolved decisions (see below).
Architecture/boundary spec; governs the downstream onboarding feature specs. Not part of the
`optimized-mapping-harbor` intro-app plan — this is a **new productization direction** layered
on the seams that plan built._

## Problem Statement
We intend to sell a local, audit-ready **Compliance Workflow Engine** as a repeatable product
across verticals (first: California home-care caregiver onboarding under CDSS/HCSB; later:
DOT driver files, KYC, any "collect → validate → track-expiry → retain for audit" domain). The
failure mode we must design out is **fork-per-customer**: copying the repo and hand-editing it
for each client, which makes every regulatory change or bug fix an N-repo manual patch — fatal
in compliance verticals where rule churn is the *source* of recurring value.

This spec defines the **boundary** that prevents that: a stable, vertical-agnostic **Core**
engine; a per-vertical **Pack** of declarative configuration + optional drop-in tools; and a
thin per-customer **Instance**. The governing invariant: **everything that varies per customer
is Pack config or Instance content — never a change to Core source.** Onboarding a new customer
becomes "author a Pack + stand up an Instance," and a Core fix ships to everyone.

This is the same *defer-the-features, build-the-seams* rule that produced the Plugin SDK
([phase4-plugin-sdk-n8n.md](phase4-plugin-sdk-n8n.md)) and the `providers/` seam — applied to
productization itself. The Plugin SDK is, in fact, the Pack's mechanism for *code* extensions;
this spec adds the *declarative* layer above it.

## Acceptance Criteria
These are design invariants — each is independently verifiable (lint/test/audit), and together
they are the whole point of the spec.

- [ ] **Zero core edits per vertical.** Standing up a brand-new vertical (its own document list,
      rules, roles, branding) requires **no diff** to the Core repos — only a new `packs/<id>/`
      bundle and an Instance config. Verifiable by building a second reference pack with the
      Core repos at a frozen commit.
- [ ] **No vertical vocabulary in Core.** Core source contains no domain-specific identifiers —
      e.g. the literal `caregiver`, `CDSS`, `live scan`, `HCA` do not appear in Core code or
      schema (they are Pack-supplied labels). The compliance subject is a generic `subject`;
      the Pack labels it "Caregiver" / "Driver" / "Customer". Verifiable by a grep-based test.
- [ ] **A Pack is declarative + additive.** A Pack consists of (a) declarative config files
      (requirements, rules, reminder schedule, roles, templates, taxonomy, KB manifest, branding)
      and (b) **optional** Plugin-SDK tool files. A Pack carries **no patches to Core**. A Pack
      that needs genuinely new *engine* behaviour is a signal to extend Core generically, not to
      fork — captured as an Open Question / Core change, never absorbed into the Pack as a hack.
- [ ] **Versioned compatibility.** A Pack manifest declares the Core version range it targets
      (`requires_core: ">=1.0,<2.0"`); Core validates this at load and refuses an incompatible
      Pack with a clear error rather than failing deep in a workflow.
- [ ] **Single-tenant per deployment.** One Instance = one customer org on their own box/data.
      The boundary does **not** introduce SaaS multi-tenancy; intra-org roles are sufficient.
      (This both simplifies the build and reinforces the local/private selling point.)
- [ ] **Reference pack proves the model.** The CA home-care onboarding pack
      (`packs/ca-homecare-onboarding/`) is authored entirely within the boundary and is the
      first consumer; a deliberately different second pack (even a thin one) is built to prove
      the seam is real, not theoretical.
- [ ] **Load-time validation, fail fast.** A malformed Pack (bad schema, dangling requirement
      reference, unknown role in an approval chain, incompatible core version) is rejected at
      startup with a precise message; a partially-valid Pack never half-loads.

## Affected Repos / Surfaces
This boundary cross-cuts the stack; the spec defines *where each responsibility lives*, not the
full build (each engine gets its own downstream feature spec).

- **ai-mcp-server-v1** — already hosts the Plugin SDK (the Pack's code-extension path,
  `tools/<name>.py` auto-discovery). Likely home of the **Pack loader/validator** and the
  generic Compliance/Workflow engine tools, since it is the async FastAPI reference impl.
- **ai-database-v1** — the generic, vertical-agnostic compliance schema (`subjects`,
  `requirements`, `submissions`, status/audit tables) keyed by Pack-supplied requirement ids,
  **not** per-vertical columns. (Concrete tables = a sibling spec; this spec fixes the
  *constraint* that they must be generic.)
- **ai-rag-llm-client-v1** — the existing RAG engine becomes the Pack's knowledge-base
  consumer (ingest the Instance's policy/reg docs); UI reads Pack-supplied labels, roles, and
  branding tokens (theme.css) rather than hard-coding a vertical.
- **ai-infrastructure-v1** — defines how a Pack + Instance are selected/mounted at deploy time
  (compose env, volume for the Pack bundle and Instance content/secrets); `ai-n8n-v1` runs the
  Pack's declarative reminder/routing workflows.
- **ai-projects** (this repo) — owns this boundary doc and the downstream feature-spec set.

> **New top-level concept:** a `packs/` folder in **ai-infrastructure-v1** holding one declarative
> bundle per vertical (mounted at deploy time beside compose + `.env`), and an Instance config
> selecting a Pack + supplying branding, secrets, and KB content.

## The boundary (the heart of this spec)

| Concern | **Core** (build once, shared, versioned) | **Pack** (per vertical, declarative) | **Instance** (per customer, thin) |
|---|---|---|---|
| Workflow state machine + audit trail | ✅ generic engine | status **labels** + which requirements gate completion | — |
| Compliance subject entity | ✅ generic `subject` | **label** ("Caregiver"/"Driver") + profile fields | the actual people/records (runtime data) |
| Required-item checklist | engine that reads it | ✅ **declares** the document/requirement list | — |
| Requirement rules (mandatory?, expiry, renewal cadence, validation) | engine that evaluates them | ✅ **declares** per requirement | — |
| Document intake (email/upload), tracking | ✅ generic | intake mailbox addr / folder mapping (values) | mailbox creds, storage path |
| OCR / field extraction pipeline | ✅ generic extractor | ✅ **field map** per document type (what to pull) | — |
| Reminder / escalation engine | ✅ generic scheduler | ✅ **cadence** (offsets, recipients, escalation) | — |
| Email / notification copy | template renderer | ✅ **templates** (with variables) | from-address, signature |
| Roles & approval chain | ✅ generic RBAC | ✅ **role names** + who approves what | the actual user accounts |
| Categorization & file naming | ✅ engine | ✅ **taxonomy** + naming convention | — |
| WORM permanent store + audit export | ✅ generic | retention period (value) | storage location, backups |
| RAG knowledge base | ✅ existing engine | KB **manifest** (which doc set, re-skin) | the actual policy/reg PDFs |
| Dashboards / metrics | ✅ generic | metric **labels** / which to surface | — |
| Branding / theme | token-driven UI | vertical default tokens (optional) | ✅ logo, name, theme overrides |
| Custom code capability | ✅ **Plugin SDK** (existing seam) | ✅ optional `tools/<name>.py` in the bundle | — |

**Rule of thumb for "Core vs Pack":** if it is a *mechanism* (how to track, route, remind,
validate, store, retrieve) it is Core. If it is a *fact about this vertical* (which documents,
what rules, what words, what cadence, whose approval) it is Pack data. If it is a *fact about
this customer* (their logo, their docs, their secrets, their people) it is Instance.

## Inputs

What a **Pack** declares (a `packs/<id>/` bundle):

| Name | Type | Source | Notes |
|---|---|---|---|
| `manifest` | config | `pack.yaml` | id, display name, vertical, pack version, `requires_core` range |
| `subject` | config | manifest | generic-entity label + profile field schema ("Caregiver", fields…) |
| `requirements[]` | config | `requirements.yaml` | id, label, category, required/conditional, expirable, validity period, renewal cadence, validation rules, extraction field map |
| `workflow` | config | `workflow.yaml` | status labels, which requirement ids gate "complete" |
| `reminders[]` | config | `reminders.yaml` | offset days, action, recipient role, escalation target |
| `roles[]` + `approvals` | config | `roles.yaml` | role names, approval chain (who signs off what) |
| `templates[]` | text | `templates/` | email/notification bodies with variable slots |
| `taxonomy` + `naming` | config | manifest | categories + file-naming convention (e.g. `{last}_{first}_{doctype}_{date}.pdf`) |
| `knowledge_base` | manifest | manifest | which KB doc set / re-skin (content supplied at Instance level) |
| `branding` | tokens | `theme.css` | optional vertical-default design tokens |
| `tools/` | code (optional) | Plugin SDK | drop-in MCP tools for vertical-specific logic (no Core edit) |

What an **Instance** supplies (deploy-time):

| Name | Type | Source | Notes |
|---|---|---|---|
| `pack_id` | env/config | compose / instance config | which Pack to load (one, to start) |
| branding overrides | tokens/assets | volume | customer logo, name, theme overrides |
| KB content | files | volume / ingest | the customer's actual policy/reg PDFs |
| secrets | env | `.env` | DB creds, mailbox creds, storage paths, API keys |

## Outputs / Response Shape
The boundary's runtime "output" is a **validated, loaded Pack** the engine serves from. The
loader exposes an introspection endpoint (mirroring the Plugin SDK's `GET /tools`) so the UI and
docs can render the active vertical without hard-coding it:

```json
{
  "pack": {
    "id": "ca-homecare-onboarding",
    "version": "1.0.0",
    "requires_core": ">=1.0,<2.0",
    "subject_label": "Caregiver",
    "requirements": [
      { "id": "tb_test", "label": "TB Test", "category": "Medical",
        "required": true, "expirable": true, "validity_days": 365,
        "extract": ["completion_date", "expiration_date", "provider"],
        "validate": ["date_present", "name_match"] }
    ],
    "reminders": [ { "offset_days": 3, "action": "friendly", "to": "subject" } ],
    "roles": ["HR", "Manager"], "status": "valid"
  }
}
```

## Data Flow
```
deploy: compose sets PACK_ID + mounts packs/<id>/ and instance content/secrets
startup (lifespan):
  → pack_loader.load(PACK_ID)
       parse pack.yaml + *.yaml + templates/      (declarative only)
       validate: schema, requires_core range, requirement refs, roles in approval chain
       discover packs/<id>/tools/*.py via existing Plugin SDK (register_tools)
       fail fast + precise error on any problem; otherwise hold validated Pack in memory
  → engines bind to Pack config (compliance reads requirements, reminders reads cadence, …)

runtime (per the downstream engines, all reading Pack config — none vertical-coded):
  intake → tracking → OCR/extract (field map) → validate (rules) → categorize (taxonomy)
         → WORM store → dashboards/RAG → completion + audit export
  every transition writes the generic audit log, keyed by subject_id + requirement_id
```

## Schema Impact
**Defines a constraint; concrete tables are a sibling spec (the compliance schema build).**
The constraint this spec fixes:

- The compliance schema must be **vertical-agnostic**: generic `subjects`, `requirements`,
  `submissions`, `requirement_status`, `audit_log` — **no** `caregiver_*` / `cdss_*` columns.
  A requirement row references a Pack-declared `requirement_id`; the Pack, not the schema,
  knows it is "TB Test."
- Ownership: every new table carries `user_id` + `deleted_at` (CLAUDE.md rule), even though
  this is single-tenant — the seam stays.
- Provenance: no new vector columns here; the RAG KB reuses the existing `VECTOR(1024)` +
  `embedding_model`/`embedding_dimension` provenance.
- The **Pack config itself** is declarative files loaded at startup, not DB rows — so a Pack
  update is a redeploy of the bundle, version-controlled in the Pack repo, not a data migration.

## Seams & Forward-Compatibility
- The **Pack loader is the seam**: it makes a new vertical additive (author a bundle) instead of
  a Core fork — the productization analogue of the Plugin SDK, `providers/`, and
  `get_current_user()` seams.
- **Plugin SDK reuse:** a Pack's `tools/` ride the existing auto-discovery
  ([phase4-plugin-sdk-n8n.md](phase4-plugin-sdk-n8n.md)); no second extension mechanism.
- **Auth seam:** `get_current_user()` + schema-only `user_id` already exist; real RBAC (Pack
  roles → actual accounts) bolts on there without a data migration.
- **Cloud-optional stays optional:** the `providers/` seam means a customer who later *wants* a
  cloud LLM is an adapter swap, but the default — and the pitch — remains fully local.
- **Multi-pack-per-instance is deferred, not precluded:** start one Pack per Instance; the
  loader signature (`load(PACK_ID)`) can grow to a list later if a customer ever needs two
  verticals on one box. Seam, not feature.

## Edge Cases & Error Handling
- **Incompatible Core version:** Pack `requires_core` unsatisfied → refuse to load at startup,
  name both versions. (Prevents a Pack silently running against an engine that changed under it.)
- **Dangling reference:** a reminder/approval/workflow that names a `requirement_id` or role not
  declared in the Pack → load fails with the offending reference.
- **Malformed Pack:** invalid YAML/schema → fail fast; never half-load a Pack (a partially-applied
  compliance config is an audit hazard).
- **Vertical vocabulary leaking into Core:** caught by the grep invariant test in CI, not at
  runtime — it is a development-time guardrail.
- **Pack tool collides with a Core tool name:** existing Plugin SDK behaviour — duplicate name
  fails fast at startup ([phase4-plugin-sdk-n8n.md](phase4-plugin-sdk-n8n.md)).
- **Missing Instance content** (no KB docs, no branding): degrade gracefully — engine runs with
  Pack defaults; UI shows a setup-incomplete state rather than crashing.

## Out of Scope for This Feature
- The concrete build of any engine (compliance schema, OCR/extraction, reminder engine, WORM
  store, dashboards, RBAC, e-sign) — each is its own downstream feature spec; this spec only
  draws the line they must respect.
- SaaS multi-tenancy; multiple Packs per Instance (deferred seam above).
- A Pack marketplace / hot-reload of Packs without restart.
- Cloud LLM/embedding adapters (the separate `providers/` seam).
- Choosing the config serialization format and the `packs/` repo location — see Open Questions.

## Test Plan
- **Unit**: `pack_loader.load()` — valid reference pack loads; each malformed case (bad schema,
  bad `requires_core`, dangling requirement ref, unknown role) raises a precise error; partial
  load never persists.
- **Boundary invariants (CI)**: grep test asserts no vertical vocabulary in Core source/schema;
  a "second vertical" fixture pack loads against frozen-commit Core with **zero** Core diff.
- **Integration** (`httpx.AsyncClient`): introspection endpoint returns the active Pack; a
  Pack-supplied `tools/` plugin is reachable and tier-enforced via the existing SDK path.
- **Manual / verify**: deploy the stack with `PACK_ID=ca-homecare-onboarding`, confirm the UI
  renders Caregiver labels/roles/branding with no code change; swap to the second pack and
  confirm the engine re-skins from config alone.

## Resolved Decisions (2026-06-26)
1. **Workflow state machine:** ✅ **Fixed lifecycle in Core (Not Sent → … → Filed); Pack supplies
   only the status *labels*.** A vertical that genuinely needs different *states* is a deliberated
   Core change, never absorbed into a Pack — this is the anti-fork guarantee in action.
2. **Pack config format:** ✅ **Hybrid — Pydantic models define the schema + validation; the
   Pack's values live in YAML/JSON data files parsed *into* those models at load.** Gives
   fail-fast validation (matching the Plugin SDK's `request_model` pattern) *and* keeps values
   editable without a code change — important because reg churn (e.g. a requirement's
   `validity_days`) is frequent and is the product's recurring-revenue driver. _(Note: this
   concerns the declarative **Pack config**, distinct from **tool** definitions, which already use
   Pydantic `request_model` via the Plugin SDK.)_
3. **Clarified — "Pack" granularity:** a Pack = a **vertical** (e.g. `ca-homecare-onboarding`),
   shared by every customer in that vertical; company-specific data is the **Instance**. A future
   `ai-packs` repo would be **our catalog of vertical templates**, never a customer's repo.
4. **Pack bundle location:** ✅ Packs live in **`ai-infrastructure-v1`** (a `packs/` folder),
   mounted at deploy time alongside `docker-compose.yml` + the shared `.env`. **Defer** promoting
   to a dedicated `ai-packs` catalog repo until vertical #2, when independent versioning/shipping
   of Packs vs. Core earns its keep.

## Open Questions
- [ ] **Profile field schema depth.** How far does the Pack-declared `subject` field schema go
      before it becomes a form-builder? Cap it for v1.
- [ ] **e-signature** ownership — Core capability vs. Pack-configured external provider — and
      whether it must be local to honour the privacy pitch.
- [ ] **First non-home-care vertical** to use as the proving "second pack" (even a thin one),
      so the seam is validated against real difference, not a toy.
- [ ] **Core versioning & upgrade delivery** to deployed Instances (image tags + `requires_core`
      gate — define the mechanism before customer #2).
```
