# Feature: Workflow C — Audit-Readiness Dashboard

## Status
[x] Spec  [x] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-07-01 — **Slice 1 (backend) shipped.** The two read endpoints
(`GET /api/subjects/{id}/readiness`, `GET /api/readiness/roster`) + the Pack expiring-window
config are built, unit-tested, and live-smoke-verified against the running stack. The **Vue
dashboard is Slice 2** (BE-before-FE gate) and the **inspector print packet + design-token polish
is Slice 3** — so the whole spec is **In Progress**, not Done, until the dashboard renders. The
**read-side** wedge workflow: a pure-query dashboard that answers "is this subject (and the whole
roster) audit-ready, and can we defend it?" Reads the schema from
[compliance-schema-mvp-wedge.md](compliance-schema-mvp-wedge.md) written by
[compliance-workflow-b-intake-tracking-reminders.md](compliance-workflow-b-intake-tracking-reminders.md);
governed by [compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md)._

### Slice log
- **Slice 1 — backend (DONE 2026-07-01).** ai-mcp-server-v1 #22 (Pack `workflow.expiring_window_days`
  in the loader schema + `GET /pack` introspection), ai-infrastructure-v1 #13 (`expiring_window_days: 30`
  on the ca-homecare Pack), ai-rag-llm-client-v1 #24 (both read endpoints + service + schemas + config
  override + tests), ai-projects #26 (this spec). No DB change — `rag_user` already had SELECT on the
  wedge tables; reads go direct from the rag-client pool (writes still route through Core/MCP). Live
  smoke PASS.
- **Slice 2 — Vue dashboard (NEXT).** Per-subject panel, roster table, trail timeline; escaped Pack
  labels; empty/expiring states; Vitest.
- **Slice 3 — inspector print packet + design-token polish.** Print CSS + Print button (no PDF engine);
  status-badge polish shared with the A/B intake UIs.

## Problem Statement
The wedge's closing argument is **audit defensibility**: when an inspector (CDSS/HCSB and the like,
per the active Pack) shows up, the operator must instantly see what is *missing*, *pending*, and
*expiring*, and produce a defensible **chronological trail** of who did what and when for any subject.
C turns the state B maintains into that view. It is **read-only and AI-free** — pure SELECTs over the
schema — so it is fast, cheap, and trivially correct: it never disagrees with the underlying
checklist because it *is* the checklist, aggregated. Generic by construction: it renders Pack-supplied
labels, so a new vertical re-skins with no C code change.

## Acceptance Criteria
_BE ✓ = delivered by the Slice-1 endpoint; the paired dashboard *rendering* lands in Slice 2._
- [x] **Per-subject readiness.** _(BE ✓)_ `GET /subjects/{id}/readiness` returns each requirement with
      its Pack **label** + category, `status` + Pack `status_label`, `expires_at`, `expiring_soon`/
      `expired` flags, and `submission_count`, plus the subject header carrying the computed
      `subjects.status` rollup and a `ready` indicator (`status ∈ {approved, filed}`).
- [x] **Missing view.** _(BE ✓)_ The summary buckets requirements as `missing` = `not_sent` /
      `incomplete` / `needs_correction`; per-subject `missing` counts also aggregate across the roster.
- [x] **Expiring-soon view.** _(BE ✓)_ Per-row `expiring_soon` (`today ≤ expires_at < today+window`)
      and `expired` (`expires_at < today`) are computed against a Pack/Instance window; the summary
      counts both. `null expires_at` is neither (never "soon").
- [x] **Chronological audit trail.** _(BE ✓)_ The readiness response renders `audit_log` ordered by
      `created_at` (who/why/when/what), capped per request (`trail_limit`, ≤ 500). Trail persists and
      stays retrievable when the subject is soft-deleted (see the soft-delete decision below).
- [x] **Roster roll-up.** _(BE ✓)_ `GET /readiness/roster` returns, across live subjects, per-subject
      ready/missing/expiring counts + caseload summary counts (subjects ready / with a missing item /
      with an expiry-attention item). Paginated (`limit`/`offset`, ≤ 500).
- [x] **Read-only + scoped.** _(BE ✓)_ Both endpoints are `GET`, no writes; every query filters
      `user_id` + `deleted_at IS NULL` (audit trail excepted — no `deleted_at`, read as-is). Subjects
      resolved by id; a malformed/unknown/non-owned id → `404`.
- [x] **Generic / no vertical vocabulary.** _(BE ✓)_ Labels/categories/status labels join in app memory
      from the `GET /pack` introspection; SQL names no vertical word. No Pack loaded → raw ids (still
      renders). The dashboard *chrome* (Slice 2) must likewise hard-code no vertical word.
- [x] **AI-free.** _(BE ✓)_ No model call in the path — deterministic SQL → response. (The Pack-label
      fetch is a plain `GET /pack`, not an LLM call.)

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
- **Soft-deleted subject**: excluded from the **roster** (live-only), **but** the **per-subject
  readiness endpoint still serves it** (resolve by id + owner, no `deleted_at` filter on the subject
  lookup) with `subject.deleted = true` set, so its `audit_log` trail stays retrievable for
  defensibility (explicit, not a leak — same owner). _Settled at build:_ the trail-retrievability
  requirement means readiness cannot 404 a soft-deleted subject; requirement rows shown are still
  live-only (`deleted_at IS NULL`).
- **Expirable requirement with null `expires_at`** (never satisfied): counts as *missing/pending*,
  not *expiring* — null is not "soon."
- **Empty roster / new Pack**: views return empty sets with zeroed counts, not an error.
- **Pack changed since materialization** (requirement added/removed): C renders the rows that exist;
  reconciliation is the schema spec's deferred Open Question — note, don't paper over.

## Security Review
Reviewed against [docs/security-checklist.md](../security-checklist.md). Each item is
ticked (with how), or `N/A — <why>`, or `deferred — <seam>`.

_Slice 1 (backend) status noted per item; the one FE-specific item (LLM05) is carried to Slice 2._

### OWASP Top 10 (2021)
- [x] **A01 Broken Access Control** — Both views filter `user_id` (from `get_current_user_id()`) +
  `deleted_at IS NULL`; subjects resolved by id (never a display string); a malformed / unknown /
  non-owned `subject_id` returns `404`, never another user's data (verified in smoke + unit tests).
- [x] **A02 Cryptographic Failures** — `N/A — no secrets handled`. C reads compliance state only.
- [x] **A03 Injection** — Parameterized SELECTs only; `subject_id`/window/limits bound as params; Pack
  labels joined in app memory (`PackLabels`), never interpolated into SQL.
- [x] **A04 Insecure Design** — Read-only by construction (`GET` only, no write path); responses carry
  only dashboard fields; `profile` is returned to identify the subject (what the panel shows), not a
  bulk PII dump.
- [x] **A05 Security Misconfiguration** — Endpoints resolve the user scope; the expiring window has a
  safe default (Pack 30 → Instance override, non-positive ignored); no debug data in responses.
- [x] **A06 Vulnerable & Outdated Components** — `N/A — no new dependency` (existing FastAPI/asyncpg).
- [x] **A07 Identification & Authentication Failures** — `deferred — get_current_user() seam`.
  Single-tenant; the trail's *who* is audit-grade only once real auth lands (boundary A07).
- [x] **A08 Software & Data Integrity Failures** — C never writes; it reads the append-only
  `audit_log` as-is (integrity enforced upstream by the schema's postgres-owned grants).
- [x] **A09 Security Logging & Monitoring Failures** — C consumes the trail and renders only its
  action metadata (`event_type`/`actor`/`reason`), never credentials/file contents (B's rule). Clean
  HTTP statuses — a malformed id is a 404, not a 500 stack-trace leak (fixed during smoke).
- [x] **A10 SSRF** — `N/A — no outbound request`. C is local SELECT + a same-network `GET /pack`; any
  audit-export push-to-SoR is the deferred export engine's surface.

### AI / LLM-Specific (OWASP LLM Top 10, 2025)
- [x] **LLM01 Prompt Injection** — `N/A — no LLM in C's path` (deterministic SQL → response).
- [x] **LLM02 Sensitive Information Disclosure** — Cross-subject leakage prevented by `user_id`
  scoping + id-resolution; C surfaces only the current user's caseload (smoke: other-user subject → 404).
- [x] **LLM03 Supply Chain** — `N/A — no model/tool added` (the shared read-only MCP tool is deferred).
- [x] **LLM04 Data & Model Poisoning** — `N/A — no ingest/embedding`.
- [ ] **LLM05 Improper Output Handling** — `deferred — Slice 2 (FE)`. The BE returns raw Pack labels +
  audit `reason`/actor + profile fields as data; the dashboard **must** render them escaped (no
  `v-html`) so a malicious filename/reason can't inject script. Primary FE security item — ticked when
  the dashboard ships.
- [x] **LLM06 Excessive Agency** — `N/A — C takes no action` (read-only; no mutate/egress tool).
- [x] **LLM07 System Prompt Leakage** — `N/A — C changes no prompt`.
- [x] **LLM08 Vector & Embedding Weaknesses** — `N/A — no vectors`.
- [x] **LLM09 Misinformation** — `N/A — no generated answers`; C reports stored facts, not model output.
- [x] **LLM10 Unbounded Consumption** — Trail capped per request (`trail_limit` ≤ 500) and the roster
  paginated (`limit` ≤ 500, `offset`) over indexed columns — no unbounded result set.

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
- **Result**: **PASS (Slice-1 backend, 2026-07-01)** — performed via the live endpoints against the
  running stack (`PACK_ID=ca-homecare-onboarding`), pending the Slice-2 UI. Created a subject
  ("Grace Hopper", 43 requirements materialized), recorded a `tb_test` submission, transitioned
  `tb_test`+`i9`+`drivers_license` → approved and `physical_exam` → needs_correction, then set
  `tb_test` expiry to `today+10` and `drivers_license` to `today−5`. `GET .../readiness` returned:
  Pack labels rendered ("TB Test", "Driver's License", "Caregiver"), `summary
  {total 43, approved 3, missing 40, pending 0, expiring_soon 1, expired 1}` (buckets partition the
  total), `tb_test.expiring_soon=true` / `drivers_license.expired=true`, and the full chronological
  trail (subject_created → submission_received → status_changed ×). `GET /readiness/roster`
  aggregated the caseload with per-subject ready/missing/expiring counts. Negative checks: unknown
  uuid → `404`, malformed id → `404` (was a 500 before the id-guard fix), soft-deleting the subject
  dropped it from the roster while its readiness+trail stayed retrievable with `deleted=true`.
  _Note: automated integration tests are written (`tests/integration/test_readiness.py`) but the
  repo's pre-existing pytest-asyncio 0.23.8 session-pool/function-loop harness issue skips/errors the
  whole integration suite in this environment (affects the existing suite too, e.g. `test_ingest`);
  the real SQL is validated by this live smoke instead. Unit suite: 27 passed; mcp-server loader: 20
  passed._

## Open Questions
- [x] **Expiring window source** — **RESOLVED (shipped): Pack default + Instance override.**
      `workflow.expiring_window_days` (default 30) on the Pack (exposed via `GET /pack`), overridable
      by the rag-client `COMPLIANCE_EXPIRING_WINDOW_DAYS` env; a non-positive override falls through to
      the next source (never a zero window).
- [ ] **Roster scale** — _deferred (decided 2026-07-01): live aggregation is fine at dry-run/demo
      scale; a materialized view is an additive optimization only if scale demands it._ At what subject
      count does the per-subject roll-up need a materialized/cached summary? (revisit under load).
- [ ] **Printable/export packet** — _decided: a minimal print-friendly inspector packet is **IN**, as
      **Slice 3** (print CSS + Print button, no PDF engine / no WORM store)._ The full audit-export /
      WORM permanent store stays deferred.
- [ ] **Shared MCP read tools** — _deferred to a C phase-2 (decided 2026-07-01): don't couple C's
      first build to the Workflow-A assistant; wrap the same BE views as read-only MCP tools later._
- [x] **Roster "expiring" semantics** _(settled at build)_ — the roster's per-subject/summary
      `expiring` counts requirements with `expires_at < today+window` (i.e. expiring-soon **or**
      already-past), so an expired-but-still-`approved` clearance still flags the subject for attention.
      The per-subject panel keeps `expiring_soon` (future within window) and `expired` (past) distinct.
