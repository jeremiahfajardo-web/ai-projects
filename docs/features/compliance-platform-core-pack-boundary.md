# Feature: Compliance Platform — Core / Pack / Instance boundary

## Status
[ ] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-29 — aligned to the current feature-spec template (added Security Review
+ standalone Smoke Test sections, reordered to match); added Core integrity/tamper-detection
coverage (Acceptance Criterion + Edge Case + two Open Questions on integrity & support boundary)
a Seams forward-dependency on sealed-image Core distribution, and a **Record Authority** section
(engagement-vs-custody postures, decoupled-app pitch, no-hard-delete, full who/why/when
traceability, redundancy; the decoupling interfaces at the MCP layer via source/sink tools); added an **Orchestration seam** (n8n vs. custom-code runner, both over
Core's enforced invariants; custom/agentic code is always a Pack — Instance stays thin).
Still the Pack model (anti-fork). Architecture/boundary spec; governs the downstream onboarding
feature specs. Not part of the `optimized-mapping-harbor` intro-app plan — this is a **new
productization direction** layered on the seams that plan built._

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
      (This both simplifies the build and reinforces the local/private selling point.) Cross-client
      isolation is therefore a **physical/deployment** boundary — no shared DB, no cross-client
      query path; `user_id` is intra-org only, never a client separator.
- [ ] **Core integrity is detectable.** Core ships as a **sealed, versioned image** (e.g.
      `core:1.4.2`), not as source, and **self-reports its image digest + version at boot**
      (extending the config-self-check guard). Drift from the published digest is detectable on
      upgrade or support. We do not *prevent* a client editing their own box (impossible for
      local software) — we **contain** it (isolation above limits blast radius to that one
      Instance), **detect** it (digest mismatch), and place it **out of support** (see Open
      Questions). The Pack model removes the *reason* to fork Core, making such edits an anomaly,
      not the operating mode.
- [ ] **Decoupled — both record-authority postures supported.** The app runs **decoupled** from
      the client's system of record, automating their workflow while they keep audit
      accountability. Two postures select per Instance behind a Core seam: **Mode A
      engagement-only (default + the pitch)** — client holds the SoR, the app works on a mutable
      copy and parks tamper-evident outputs for their systems to retain; **Mode B full custody
      (opt-in)** — the app is the SoR. Switching posture requires **no Core edit**.
- [ ] **No hard deletes.** No code path hard-deletes any record in either posture; everything is
      soft-deleted (`deleted_at`) and retained, history append-only. A lawful-erasure obligation
      is met by redaction / crypto-shred-with-tombstone, never a destructive `DELETE` (see Open
      Questions).
- [ ] **Full action traceability (who / why / when / what).** Every state-changing action — human
      **or** AI-initiated — writes an attributed audit entry: initiating actor, reason (the
      trigger/justification), timestamp, and the entity/requirement touched. AI-automated actions
      are as traceable and explainable as human ones.
- [ ] **Built for redundancy.** Neither the working copy nor the parked handoff stream is a single
      point of loss; the data and the output handoff are redundant.
- [ ] **Pluggable orchestration; invariants enforced beneath it.** Workflow orchestration is a
      swappable backend behind a Core seam — **n8n (declarative, default) or a custom-code runner
      plugin** — selected per Pack with **no Core edit**, all backends sharing the same MCP tools.
      Whichever backend runs, it goes **through Core's enforced primitives**, so no-hard-delete,
      traceability, and the record-authority handoff **cannot be bypassed** by a Pack's runner or
      tools. Verifiable: a custom-code runner cannot hard-delete or skip the audit trail.
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
  generic Compliance/Workflow engine tools, since it is the async FastAPI reference impl. Also the
  home of the **record-authority source/sink tools** — the decoupling interfaces here, at the MCP
  layer (a client's SoR connector is a drop-in `tools/` plugin).
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
| Workflow orchestration (triggers, sequence, schedule) | ✅ generic agentic loop + runner **seam** | ✅ n8n workflows **or** a custom-code runner plugin (`tools/`) | — |
| Custom code capability | ✅ **Plugin SDK** (existing seam) | ✅ optional `tools/<name>.py` in the bundle | — |

**Rule of thumb for "Core vs Pack":** if it is a *mechanism* (how to track, route, remind,
validate, store, retrieve) it is Core. If it is a *fact about this vertical* (which documents,
what rules, what words, what cadence, whose approval) it is Pack data. If it is a *fact about
this customer* (their logo, their docs, their secrets, their people) it is Instance.

## Record Authority — engagement vs. custody (decoupled by design)
The product is pitched as a **decoupled automation app**: it **automates the client's compliance
workflow while the client retains accountability for their audits**. It supports two postures,
selected per Instance behind a Core seam — **Mode A is the default and the pitch:**

- **Mode A — engagement-only (default).** The client's own systems are the **system of record
  (SoR)**. The app operates on a **mutable working copy**, runs the automated workflow, and
  **"parks" its outputs** (extracted fields, validation results, status changes, generated
  documents, the action-audit stream) at a defined **handoff location** in a documented,
  **tamper-evident** format for the client's systems to collect and retain. The app never claims
  custody of the authoritative record; the client's store wins on any conflict. RAG fits this
  natively — retrieval is already over a derived copy, never the original.
- **Mode B — full custody (opt-in).** The app itself is the SoR (durable retained store + audit
  export) for clients who want one-box simplicity.

Three product-wide invariants hold in **either** posture:
- **No hard deletes, ever.** Every entity is soft-deleted (`deleted_at`) and retained; history is
  append-only. A Mode-A working copy is still traceable and retained, not discarded — we chose
  traceability over ephemerality.
- **Full traceability.** Every state-changing action — human **or** AI-initiated — records
  **who** initiated it, **why** (the trigger/justification), **when**, and **what** it touched.
  AI-automated actions are as attributable and explainable as human ones — central to the
  AI-wariness pitch.
- **Built for redundancy.** Neither the working copy nor the parked handoff stream is a single
  point of loss.

Mapping onto the boundary: the **record-authority seam + working-copy lifecycle + traceability
log** are **Core**; the **audit/handoff format** a vertical's auditors expect is **Pack**; the
**posture toggle (A/B) + parking location/credentials + the client SoR endpoint** are
**Instance**. The seam *extends* the model rather than breaking it.

**The decoupling interfaces at the MCP layer.** The seam is realized as MCP **source/sink tools**
on the existing Plugin SDK — not a bespoke subsystem: a *source* tool pulls the working copy, a
*sink* ("park") tool writes tamper-evident outputs to the client's SoR. Because a client's
existing system is bespoke, **its connector is a Pack- or Instance-level `tools/` plugin** —
drop-in, auto-discovered, **no Core edit** — and rides the SDK's tier-enforcement and the
traceability stamp like any other tool.

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
- **No hard delete:** every table soft-deletes (`deleted_at`); there is **no destructive `DELETE`
  path** in either posture. Retention is by soft-delete + (Mode A) the client SoR — never by row
  removal.
- **Traceability / action log:** the generic audit log records, per action, **actor + reason +
  timestamp + action + target** — not merely `subject_id`/`requirement_id` — append-only and
  actor-attributed. AI-initiated actions stamp the agent identity + authorizing user + the
  trigger that fired them.
- **Mode A handoff** is an **export artifact** (documented, tamper-evident format) produced *from*
  — not a substitute for — the generic tables; the client's SoR is the durable store. Mode B
  retains in-app.

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
- **Record-authority seam:** the app is decoupled from the client's system of record. A Core seam
  selects the posture — **intake** end pulls a minimized **working copy** (client store
  authoritative on conflict); **output** end **parks** tamper-evident results at a handoff
  location for the client's systems. Vertical-expected **handoff/audit format** is Pack; the
  **posture toggle + parking location / SoR endpoint** are Instance. Default Mode A — see the
  *Record Authority* section. Lets a client run fully decoupled now and adopt full custody (Mode
  B) later without a Core change. Realized at the **MCP layer** — source/sink tools via the Plugin
  SDK — so a client's bespoke SoR connector is a drop-in `tools/` plugin, not Core.
- **Orchestration seam (n8n vs. custom code):** n8n owns only *orchestration* (when / what order),
  declaratively — it is **one backend** of a Core runner seam, not the seam itself. A client who
  refuses n8n swaps the backend for a **custom-code runner plugin** (Pack `tools/`, auto-discovered)
  or the direct Core agentic loop — **no Core edit**. All backends consume the **same MCP tools**
  (the capability layer); only the orchestrator changes. Declarative n8n is the safer default;
  custom code is the opt-in escalation (bigger blast radius — A08/LLM06).
- **Invariants are enforced beneath extensions, not by them.** Custom code *and* n8n go **through
  Core's enforced primitives** (persistence API, tool layer, record-authority sink) — never
  straight to the DB or client SoR. So **no-hard-delete, traceability stamping (who/why/when/what),
  and the record-authority handoff hold regardless of what a Pack's runner/tools do**: an extension
  adds capability *above* the invariants, never reaches *around* them. This is what makes
  "separated" real once a client can write code.
- **Forward dependency — sealed-image distribution.** The Core integrity story (Acceptance
  Criterion "Core integrity is detectable" + the boot-time digest self-report) assumes Core is
  delivered to clients as a **sealed, versioned image, not source**. That distribution/build
  pipeline — how a client receives, verifies, and runs that image, and where the published-digest
  baseline lives — is **not specced here** and is a prerequisite for the integrity + upgrade-delivery
  Open Questions. It is its own downstream spec —
  [compliance-platform-core-release-distribution.md](compliance-platform-core-release-distribution.md)
  (a **parked stub**, required before customer #1). Flagged so the dependency is explicit rather
  than assumed.

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
- **Client modifies Core in place:** possible on their own hardware and **not technically
  preventable** for local software. **Contained** to that one Instance (single-tenant boundary —
  no effect on other clients), **detected** on upgrade/support via image-digest mismatch against
  the published digest, and **out of support** per the warranty boundary. A subsequent Core
  upgrade (image replace) overwrites the in-place edit, or the `requires_core` gate flags an
  incompatibility — the modification does not silently persist across an upgrade.

## Security Review
Reviewed against [docs/security-checklist.md](../security-checklist.md). Each item is
ticked (with how), or `N/A — <why>`, or `deferred — <seam>`.

This is a **boundary/architecture spec** — it ships no runtime code itself, so most concrete
controls are `deferred` to the downstream engine specs that build them. The items addressed
here are the ones the **boundary itself governs**: the Pack as a trust boundary (A08/LLM03),
Pack-supplied `tools/` widening agency (LLM06), fail-fast load-time validation (A05), the
secrets/Pack separation (A02), and the constraint that the generic schema carry the ownership
seam (A01).

### OWASP Top 10 (2021)
- [ ] **A01 Broken Access Control** — `deferred — get_current_user() + schema seam`. This spec
  *mandates* every generic compliance table carry `user_id` + `deleted_at` (see Schema Impact);
  enforcing the filter is the downstream compliance-schema build's job.
- [x] **A02 Cryptographic Failures** — Pack bundles are **non-secret, version-controlled
  declarative config**; all secrets (DB/mailbox creds, storage paths, API keys) are
  **Instance**-level `.env`/volume, never in a Pack. The boundary keeps the two apart by design.
- [ ] **A03 Injection** — `deferred — Pydantic-validated Pack config + parameterized queries`.
  Pack values parse into Pydantic models (Resolved Decision #2); concrete SQL lives downstream
  and follows the parameterized-only rule.
- [x] **A04 Insecure Design** — This spec *is* an insecure-design control: the anti-fork
  boundary + fail-fast Pack loader prevent the N-repo divergence that makes reg fixes unsafe.
- [x] **A05 Security Misconfiguration** — Load-time validation rejects malformed/partial Packs
  and out-of-range `requires_core` with a precise error at startup; a Pack never half-loads.
- [ ] **A06 Vulnerable & Outdated Components** — `deferred — per-engine build`. A Pack's
  optional `tools/` are code and inherit the pinned-deps + reviewed-image rules when built.
- [ ] **A07 Identification & Authentication Failures** — `deferred — auth seam exists`.
  Single-tenant per Instance; Pack-declared roles → real accounts bolts onto `get_current_user()`.
  **Tension:** the traceability invariant's *who* is only legally meaningful once real auth lands
  — until then the actor is the default local user. Auth is therefore a **prerequisite for
  audit-grade attribution**, not merely deferred polish.
- [x] **A08 Software & Data Integrity Failures** — **The Pack loader is a trust boundary.** A
  Pack's `tools/` ride the existing Plugin-SDK auto-discovery — only load Packs from a trusted
  catalog (our `packs/`/future `ai-packs`), never customer-supplied unreviewed code. A custom-code
  **orchestration runner** (the n8n alternative) is the largest such surface — same rule: reviewed
  catalog only, always a Pack (Resolved Decision #5), pinned via `requires_core`.
- [x] **A09 Security Logging & Monitoring Failures** — This spec elevates **actor-attributed
  traceability** (who / why / when / what, append-only, **no hard delete**) to a product invariant
  (see Acceptance Criteria + Record Authority). The concrete log schema + enforcement is the
  downstream engine build; legal-grade attribution depends on the auth seam (A07); never log
  secrets.
- [ ] **A10 SSRF** — `deferred — per Pack tool review`. The Core engine adds no new outbound
  path; a Pack `tools/` plugin that reaches the network must be reviewed against A10 at author
  time (same gate as any MCP tool). The **Mode-A park/push-to-SoR sink tool** (decoupling at the
  MCP layer) is exactly such an outbound path — allowlist the SoR endpoint, reject
  internal-network / metadata-endpoint targets.

### AI / LLM-Specific (OWASP LLM Top 10, 2025)
- [ ] **LLM01 Prompt Injection** — `deferred — RAG KB build`. Instance KB docs become retrieved
  context (indirect-injection surface); delimiting is the downstream RAG ingest spec's concern.
- [ ] **LLM02 Sensitive Information Disclosure** — `deferred — user_id scoping`. Boundary
  mandates the ownership seam; cross-subject leakage is enforced in the engine build.
- [x] **LLM03 Supply Chain** — A Pack (config + `tools/` + KB manifest) is a supply-chain input;
  Packs come from our reviewed catalog and pin/justify any tool dependency — not customer code.
- [ ] **LLM04 Data & Model Poisoning** — `deferred — ingest path`. Instance KB content becomes
  retrievable context; who may supply/ingest it is governed where ingest is built.
- [ ] **LLM05 Improper Output Handling** — `deferred — UI build`. The UI renders **Pack-supplied
  labels/branding**; those strings (and any model output) must be escaped (no `v-html`) in the
  client spec.
- [x] **LLM06 Excessive Agency** — A Pack's optional `tools/*.py` widen what the model can do per
  vertical. Each must justify its blast radius and ride the least-capability Plugin-SDK path;
  the boundary forbids a Pack adding agency via a Core edit (it must be a reviewed tool). The
  **record-authority sink tool** writes to the client SoR (state-mutating + egressing) — scope it
  to least capability and stamp every write into the traceability log.
- [ ] **LLM07 System Prompt Leakage** — `N/A — this spec changes no prompt`. System-prompt
  exposure remains the existing (intentional, secret-free) UI behaviour.
- [ ] **LLM08 Vector & Embedding Weaknesses** — `N/A — no new vector columns`. The RAG KB reuses
  the existing `VECTOR(1024)` + `embedding_model`/`embedding_dimension` provenance.
- [ ] **LLM09 Misinformation** — `deferred — RAG answer path`. Grounded-with-citations behaviour
  is the existing RAG engine's; unchanged by the boundary.
- [ ] **LLM10 Unbounded Consumption** — `deferred — per-engine build`. Reminder/extraction loops
  and any cloud-provider cost caps are bounded where those engines are built.

## Out of Scope for This Feature
- The concrete build of any engine (compliance schema, OCR/extraction, reminder engine, WORM
  store, dashboards, RBAC, e-sign) — each is its own downstream feature spec; this spec only
  draws the line they must respect.
- SaaS multi-tenancy; multiple Packs per Instance (deferred seam above).
- A Pack marketplace / hot-reload of Packs without restart.
- Cloud LLM/embedding adapters (the separate `providers/` seam).
- Choosing the config serialization format and the `packs/` repo location — see Open Questions.
- The concrete **orchestration-runner interface** + any custom-runner implementation. This spec
  fixes that orchestration is a **pluggable Pack-level backend over Core's enforced primitives**
  (n8n or custom code); building the interface and a custom runner is a downstream feature spec.

## Test Plan
- **Unit**: `pack_loader.load()` — valid reference pack loads; each malformed case (bad schema,
  bad `requires_core`, dangling requirement ref, unknown role) raises a precise error; partial
  load never persists.
- **Boundary invariants (CI)**: grep test asserts no vertical vocabulary in Core source/schema;
  a "second vertical" fixture pack loads against frozen-commit Core with **zero** Core diff.
- **Integration** (`httpx.AsyncClient`): introspection endpoint returns the active Pack; a
  Pack-supplied `tools/` plugin is reachable and tier-enforced via the existing SDK path.

## Smoke Test (user-performed, on the running stack)
A documented manual check so the live verification is traceable and repeatable — green pytest is
not "done" (see CLAUDE.md). _Runnable only once a downstream engine implements the Pack loader;
recorded here so the boundary's proof-of-concept is traceable when that slice ships._
- **Pre-reqs / config**: a Core build exposing `pack_loader` + the introspection endpoint; the
  reference `packs/ca-homecare-onboarding/` bundle and a deliberately-different second pack
  mounted; set `PACK_ID` in `ai-infrastructure-v1/.env`; `docker compose up -d --build`.
- **Steps**:
  1. Boot with `PACK_ID=ca-homecare-onboarding`; `GET` the introspection endpoint.
  2. Open the UI; observe subject/role/branding labels.
  3. Stop, set `PACK_ID=<second-pack>`, recreate the container, repeat steps 1–2.
- **Expected / pass criteria**: introspection returns the active Pack (`"status": "valid"`,
  correct `subject_label`/requirements); UI renders **Caregiver** labels/roles/branding with
  **no code change**; the second pack re-skins the engine from config alone — Core repos at a
  frozen commit, **zero diff**.
- **Negative / fallback check**: mount a malformed Pack (dangling `requirement_id`, unknown role,
  or out-of-range `requires_core`) → startup **fails fast** with a precise message naming the
  offending reference; the Pack never half-loads.
- **Result**: _pending — boundary spec; to be recorded when the loader slice ships._

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
5. **Custom / agentic code is always a Pack — Instance stays thin.** A client who wants custom code
   instead of (or alongside) n8n gets it as a **Pack `tools/` / runner plugin**, *even when only
   one customer uses it* (a single-consumer Pack). The boundary does **not** add an Instance-level
   code overlay: keeping all code under the reviewed catalog + `requires_core` versioning is worth
   more than per-deployment flexibility. Instance stays **declarative** (config, secrets, content)
   — never bespoke code. Workflow orchestration (n8n vs. custom runner) is therefore a **Pack**
   choice over a Core seam, and runs above Core's enforced invariants (see Seams).

## Open Questions
- [ ] **Profile field schema depth.** How far does the Pack-declared `subject` field schema go
      before it becomes a form-builder? Cap it for v1.
- [ ] **e-signature** ownership — Core capability vs. Pack-configured external provider — and
      whether it must be local to honour the privacy pitch.
- [ ] **First non-home-care vertical** to use as the proving "second pack" (even a thin one),
      so the seam is validated against real difference, not a toy.
- [ ] **Core versioning & upgrade delivery** to deployed Instances (image tags + `requires_core`
      gate — define the mechanism before customer #2).
- [ ] **Core integrity / tamper detection mechanism** — confirm sealed-image distribution + the
      boot-time digest self-report (where the published-digest baseline lives, how a mismatch
      surfaces on upgrade/support). Pairs with the upgrade-delivery question above. **Parked in its
      own stub:** [compliance-platform-core-release-distribution.md](compliance-platform-core-release-distribution.md).
- [ ] **Support / warranty boundary wording** — the contractual statement that support covers
      only the unmodified published Core image digest, and that modifying Core voids support and
      may be overwritten on upgrade. A legal/commercial decision, not a code one — flagged here so
      it is settled before customer #1. (Cross-referenced from the distribution stub's licensing
      Open Question.)
- [ ] **Record-authority handoff contract (Mode A).** Parking **format & transport** (client
      pulls a folder/queue we write vs. we push to their endpoint — **realized as an MCP
      source/sink tool**); **tamper-evidence** (hash/sign
      parked outputs); **authoritative-on-conflict + refresh** between the working copy and the
      client SoR; **working-copy lifecycle** under the no-hard-delete rule (encrypted at rest, how
      long resident).
- [ ] **Default posture per vertical** — confirm Mode A (engagement-only) is the default for these
      AI-wary verticals, with Mode B (full custody) an explicit opt-in.
- [ ] **Lawful erasure vs. no-hard-delete.** How a CCPA/CPRA erasure request is honoured when
      nothing is hard-deleted — redaction / crypto-shred with a retained tombstone — and that in
      Mode A the decision is the client SoR's, our copy acting on their instruction.
- [ ] **Redundancy mechanism** — what redundancy is actually guaranteed for the working copy and
      the parked handoff, and whose responsibility it is in Mode A (client) vs. Mode B (us).
```
