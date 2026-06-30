# Feature: Workflow C — Audit-Readiness Dashboard

## Status
[x] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-29 — initial authored draft. The **read-side** wedge workflow: a pure-query
dashboard that answers "is this subject (and the whole roster) audit-ready, and can we defend it?"
Reads the schema from [compliance-schema-mvp-wedge.md](compliance-schema-mvp-wedge.md) written by
[compliance-workflow-b-intake-tracking-reminders.md](compliance-workflow-b-intake-tracking-reminders.md);
governed by [compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md)._

## Problem Statement
The wedge's closing argument is **audit defensibility**: when an inspector (CDSS/HCSB and the like,
per the active Pack) shows up, the operator must instantly see what is *missing*, *pending*, and
*expiring*, and produce a defensible **chronological trail** of who did what and when for any subject.
C turns the state B maintains into that view. It is **read-only and AI-free** — pure SELECTs over the
schema — so it is fast, cheap, and trivially correct: it never disagrees with the underlying
checklist because it *is* the checklist, aggregated. Generic by construction: it renders Pack-supplied
labels, so a new vertical re-skins with no C code change.

## Acceptance Criteria
- [ ] **Per-subject readiness.** For a subject, C shows each requirement with its Pack **label**,
      `status`, `expires_at`, and submission count, plus an overall readiness indicator derived from
      the requirement rows (the computed `subjects.status` rollup).
- [ ] **Missing view.** A query returns requirements in `not_sent` / `incomplete` /
      `needs_correction` (the "owed" set) per subject and across the roster.
- [ ] **Expiring-soon view.** A query returns requirements with `expires_at < now() + 30d` (window
      Pack/Instance-configurable), and separately the already-expired set.
- [ ] **Chronological audit trail.** For a subject, C renders `audit_log` ordered by `created_at`:
      who / why / when / what for every state change — the defensibility narrative. Trail rows persist
      even when the subject is soft-deleted.
- [ ] **Roster roll-up.** Across all live subjects under the active Pack: counts of ready / missing /
      expiring, so the operator triages the whole caseload, not one subject at a time.
- [ ] **Read-only + scoped.** C performs **no writes**; every query filters `user_id` +
      `deleted_at IS NULL` (audit trail excepted — it has no `deleted_at` and is read as-is).
- [ ] **Generic / no vertical vocabulary.** All labels, role names, and category headings come from
      the active Pack; C hard-codes no requirement name or vertical word.
- [ ] **AI-free.** No model call in C's path; the dashboard is deterministic SQL → render.

## Affected Repos / Surfaces
- **ai-rag-llm-client-v1** (primary): read-only **BE endpoints** (the C views as parameterized
  SELECTs) + the **FE dashboard** (Vue: per-subject panel, roster table, trail timeline). **BE-before-FE
  gate** — endpoints built + tested before the dashboard UI.
- **ai-mcp-server-v1**: optional — expose the same readiness views as **read-only MCP tools** so the
  Workflow-A assistant can answer "what's missing for <subject>?" from the same source of truth (no
  duplicate query logic). Out of scope for the first slice unless cheap.
- **ai-database-v1**: no schema change — relies on the schema spec's indexes
  (`requirement_status(subject_id)`, partial `(expires_at)`, `audit_log(subject_id, created_at)`).

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| `pack_id` | text | active Pack (env) | supplies labels/roles/categories the views render |
| `subject_id` | uuid | UI route | resolve by id, never display string |
| `expiring_window_days` | int | Pack/Instance config | default 30; the "expiring soon" horizon |
| `current_user` | uuid | `get_current_user()` seam | scopes every query |

## Outputs / Response Shape
```json
{
  "subject": { "id": "uuid", "label": "<Pack subject label>", "status": "in_progress",
               "ready": false },
  "summary": { "total": 6, "approved": 3, "missing": 2, "pending": 1, "expiring_soon": 1 },
  "requirements": [
    { "requirement_id": "<pack id>", "label": "<Pack label>", "category": "<Pack category>",
      "status": "approved", "expires_at": "2027-07-01", "expiring_soon": false,
      "submission_count": 1 }
  ],
  "trail": [
    { "at": "2026-06-29T10:00:00Z", "actor": "default", "actor_kind": "human",
      "event_type": "submission_received", "requirement_id": "<pack id>", "reason": "uploaded" }
  ]
}
```

## Data Flow
```
GET /api/subjects/{id}/readiness
  → SELECT requirement_status WHERE subject_id=? AND user_id=? AND deleted_at IS NULL
  → join Pack labels/categories in memory (from pack_loader) — no vertical column in SQL
  → compute summary + per-row expiring_soon (expires_at < now()+window)
  → SELECT audit_log WHERE subject_id=? ORDER BY created_at        (the trail)

GET /api/readiness/roster
  → SELECT requirement_status JOIN subjects (live only) WHERE user_id=?
  → aggregate per subject: ready? / missing count / expiring count
  → counts for the whole caseload

views (pure SELECT, no AI):
  missing      → status IN (not_sent, incomplete, needs_correction)
  pending      → status IN (sent, opened, in_progress, returned)
  expiring     → expires_at < now()+window AND deleted_at IS NULL
  expired      → expires_at < now()
```

## Schema Impact
**None.** C is read-only over the five wedge tables and their existing indexes. If the roster roll-up
proves slow at scale, a future materialized view is an additive optimization (not in this slice).
- Ownership: ✅ reads filter `user_id` + `deleted_at IS NULL`.
- Provenance: N/A — no vectors.

## Seams & Forward-Compatibility
- **`subjects.status` as computed rollup** (schema Open Q #1, decided in B): C *consumes* the rollup
  rather than trusting a separately-edited field, so the dashboard cannot drift from the checklist.
- **`audit_log` → WORM export.** The chronological trail is the precursor to the deferred **audit
  export / WORM permanent store**: C renders it now; a later engine mirrors the same ordered stream
  to an immutable store + a printable inspector packet.
- **Dashboard metrics are Pack-labelled.** Which metrics surface and their headings are Pack config
  (boundary table) — C renders them, so a new vertical changes labels, not C code.
- **Shared read tools.** Exposing the views as MCP tools (optional above) lets Workflow A answer
  readiness questions from the identical query path — one source of truth.

## Edge Cases & Error Handling
- **Subject not found / not owned**: `404` (resolve by id; never leak another user's subject).
- **Soft-deleted subject**: excluded from roster + per-subject readiness, **but** its `audit_log`
  trail remains retrievable for defensibility (explicit, not a leak — same owner).
- **Expirable requirement with null `expires_at`** (never satisfied): counts as *missing/pending*,
  not *expiring* — null is not "soon."
- **Empty roster / new Pack**: views return empty sets with zeroed counts, not an error.
- **Pack changed since materialization** (requirement added/removed): C renders the rows that exist;
  reconciliation is the schema spec's deferred Open Question — note, don't paper over.

## Security Review
Reviewed against [docs/security-checklist.md](../security-checklist.md). Each item is
ticked (with how), or `N/A — <why>`, or `deferred — <seam>`.

### OWASP Top 10 (2021)
- [ ] **A01 Broken Access Control** — Every view filters `user_id` (from `get_current_user()`) +
  `deleted_at IS NULL`; subjects resolved by id, never display string; a non-owned `subject_id`
  returns `404`, never another user's data.
- [ ] **A02 Cryptographic Failures** — `N/A — no secrets handled`. C reads compliance state only.
- [ ] **A03 Injection** — Parameterized SELECTs only; `subject_id`/window bound as params; Pack
  labels joined in app memory, not interpolated into SQL.
- [ ] **A04 Insecure Design** — Read-only by construction (no write path to misuse); responses expose
  only the fields the dashboard needs (no over-fetch of profile PII beyond what's shown).
- [ ] **A05 Security Misconfiguration** — Read endpoints require the user scope; the expiring window
  has a safe default; no debug data leak in responses.
- [ ] **A06 Vulnerable & Outdated Components** — `N/A — no new dependency` (uses the existing
  FastAPI/SQL stack).
- [ ] **A07 Identification & Authentication Failures** — `deferred — get_current_user() seam`.
  Single-tenant; the trail's *who* is audit-grade only once real auth lands (boundary A07).
- [ ] **A08 Software & Data Integrity Failures** — C never writes; it reads the append-only
  `audit_log` as-is (integrity is enforced upstream by the schema's grants).
- [ ] **A09 Security Logging & Monitoring Failures** — C is a *consumer* of the audit trail; it must
  not render secrets — `detail`/`reason` are action metadata, never credentials/file contents (B's
  rule). Clean HTTP statuses, no stack traces to the client.
- [ ] **A10 SSRF** — `N/A — no outbound request`. C is local SELECT + render; any audit-export
  push-to-SoR is the deferred export engine's surface.

### AI / LLM-Specific (OWASP LLM Top 10, 2025)
- [ ] **LLM01 Prompt Injection** — `N/A — no LLM in C's path` (deterministic SQL → render).
- [ ] **LLM02 Sensitive Information Disclosure** — Cross-subject leakage prevented by `user_id`
  scoping + id-resolution; C surfaces only the current user's caseload.
- [ ] **LLM03 Supply Chain** — `N/A — no model/tool added` (optional read-only MCP tool reuses the
  existing reviewed SDK path).
- [ ] **LLM04 Data & Model Poisoning** — `N/A — no ingest/embedding`.
- [ ] **LLM05 Improper Output Handling** — The dashboard renders **Pack labels + audit `reason`/actor
  + profile fields** — all escaped (no `v-html`); a malicious filename/reason can't inject script.
  Primary FE security item.
- [ ] **LLM06 Excessive Agency** — `N/A — C takes no action` (read-only; no tools that mutate/egress).
- [ ] **LLM07 System Prompt Leakage** — `N/A — C changes no prompt`.
- [ ] **LLM08 Vector & Embedding Weaknesses** — `N/A — no vectors`.
- [ ] **LLM09 Misinformation** — `N/A — no generated answers`; C reports stored facts, not model
  output.
- [ ] **LLM10 Unbounded Consumption** — Roster/trail queries are bounded + indexed; paginate the
  roster and cap trail length per request to avoid an unbounded result set.

## Out of Scope for This Feature
- Any **write** / status change / reminder — that is Workflow B.
- The **audit export / WORM permanent store** and a printable inspector packet (deferred engine; C
  renders the live trail only).
- OCR-derived fields / scan-quality scores in the view (deferred Workflow D).
- Cross-subject analytics / trend reporting beyond the readiness roll-up.
- Real RBAC/auth; multi-tenancy.

## Test Plan
- **Unit** (mock DB + Pack): missing/pending/expiring classification is correct at the boundaries
  (null `expires_at`, exactly `now()+window`, already-expired); summary counts match rows; trail is
  ordered by `created_at`.
- **Integration** (`httpx.AsyncClient` + test DB seeded by B's writes): per-subject readiness + roster
  return correct rows; a soft-deleted subject drops from readiness but its trail is still retrievable;
  a non-owned `subject_id` → `404`.
- **Frontend** (Vitest): readiness panel renders Pack labels (escaped); expiring rows badge correctly;
  empty roster renders a zeroed state, not an error.

## Smoke Test (user-performed, on the running stack)
- **Pre-reqs / config**: stack up; `PACK_ID=ca-homecare-onboarding`; a subject worked via Workflow B
  (some approved, one `needs_correction`, one expirable approved with a near `expires_at`).
- **Steps**:
  1. Open the subject's readiness panel; confirm labels are Pack-supplied, statuses match B's writes,
     and the overall indicator reflects the rollup.
  2. Confirm the *missing* list shows the `needs_correction` item and the *expiring-soon* list shows
     the near-expiry item.
  3. Open the audit trail; confirm chronological who/why/when/what entries for every change B made.
  4. Open the roster; confirm caseload counts (ready / missing / expiring) tally.
- **Expected / pass criteria**: dashboard is correct and Pack-labelled with **no code change**;
  read-only (no mutation possible from C).
- **Negative / fallback check**: request a `subject_id` owned by no one / another user → `404`;
  soft-delete the subject in B → it leaves the roster but its trail still renders for defensibility.
- **Result**: _<pending — fill when built>_

## Open Questions
- [ ] **Expiring window source** — fixed 30d, Pack-declared, or Instance-tunable? (Leaning
      Pack-default + Instance override.)
- [ ] **Roster scale** — at what subject count does the per-subject roll-up need a materialized view
      or cached summary rather than live aggregation?
- [ ] **Printable/export packet** — does the wedge need even a basic print/PDF of the readiness view
      for inspectors, or is that fully the deferred audit-export engine? (Pitch may want a minimal
      print now.)
- [ ] **Shared MCP read tools** — expose readiness as MCP tools for Workflow A in this slice, or
      defer to avoid coupling C's first build to the assistant?
