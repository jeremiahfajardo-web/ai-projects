# Feature: Compliance schema — MVP wedge (tracking, reminders, audit-readiness)

## Status
[ ] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-26 — initial draft. The **minimal** generic schema behind the sellable
wedge (Workflows B + C). Deliberately smaller than the full compliance platform; grows into it
without rework. Governed by [compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md)._

## Problem Statement
We're selling-first with a three-workflow wedge: **A** Policy assistant (RAG, already built),
**B** Intake + tracking + reminders, **C** Audit-readiness dashboard. B and C both need persisted
state — *what does this subject owe, what's been received, what's its status, when does it
expire* — and an append-only event trail to defend a CDSS inspection. This spec defines the
**smallest generic schema** that supports B and C, on the vertical-agnostic Core foundation so
"caregiver" stays **data, not columns**, and so the deferred engines (OCR extraction, WORM
permanent store, renewal automation) bolt on later without a migration rewrite.

## Acceptance Criteria
- [ ] A `subject` can be created under a Pack, and the system materializes one
      **requirement-status** row per requirement the active Pack declares — so B/C have a complete
      checklist from creation, with no per-vertical columns.
- [ ] A received document is recorded as a **submission** tied to its subject + Pack
      `requirement_id`, with source (email / upload / in-person) and timestamps — powering B's
      "what's been sent/received" tracking.
- [ ] Each requirement-status carries a **status** from the fixed Core lifecycle and an optional
      **`expires_at`** — so C can compute *missing*, *pending*, and *expiring-soon* by query alone.
- [ ] Every state change (created, sent, received, status change, reminder sent, approved) writes
      an **append-only audit-log** row — the defensibility trail for C's audit view.
- [ ] **No vertical vocabulary in the schema.** Tables are `subjects` / `requirement_status` /
      `submissions` / `reminders` / `audit_log`; the words `caregiver`/`CDSS`/`TB`/`live scan`
      appear nowhere in DDL. Verifiable by the boundary grep test.
- [ ] `requirement_id` references a **Pack-declared id** (config), validated against the active
      Pack at write time — **not** a FK to a DB requirements table (requirements live in Pack
      config, not the DB).
- [ ] Every owned table carries `user_id` + `deleted_at` (CLAUDE.md rule), even though the
      deployment is single-tenant — the auth/soft-delete seam stays. `audit_log` is the
      exception: append-only, no soft-delete.

## Affected Repos / Surfaces
- **ai-database-v1** (primary): new Alembic migration adding the five tables + indexes; least-
  privilege grants for the app user(s).
- **ai-mcp-server-v1 / ai-rag-llm-client-v1**: will read/write these via services (their build is
  the B/C feature specs — out of scope here; this spec is the schema only).
- **ai-infrastructure-v1**: the active `PACK_ID` (from the boundary spec) determines which
  requirement set materializes — no compose change for the schema itself.

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| `pack_id` | text | active Pack (env) | stamped on each subject; ties runtime data to the vertical |
| `subject.profile` | jsonb | UI (Pack-defined fields) | first/last/email/etc. as declared by the Pack's `subject` schema — **no fixed columns** |
| `requirement_id` | text | Pack config | e.g. `tb_test`; validated against the active Pack, not FK'd |
| `submission` file ref | text/uuid | upload / email intake | path or blob id; **no OCR/extraction in the wedge** — status is set by a human |
| status | enum | Core lifecycle | `not_sent / sent / opened / in_progress / returned / incomplete / needs_correction / approved / filed` |

## Outputs / Response Shape
Schema, not an endpoint. The shape B/C read (illustrative):
```json
{
  "subject": { "id": "uuid", "pack_id": "ca-homecare-onboarding",
               "profile": { "first": "John", "last": "Smith" }, "status": "in_progress" },
  "requirements": [
    { "requirement_id": "tb_test", "status": "approved",
      "expires_at": "2027-07-01", "submission_count": 1 },
    { "requirement_id": "driver_license", "status": "not_sent", "expires_at": null }
  ]
}
```

## Data Flow
```
create subject (POST, future B/C service)
  → INSERT subjects (pack_id, profile jsonb, status='in_progress', user_id)
  → load active Pack.requirements  → INSERT one requirement_status per requirement_id (status='not_sent')
  → INSERT audit_log (event='subject_created')

receive a document
  → INSERT submissions (subject_id, requirement_id, source, received_at, received_by, user_id)
  → UPDATE requirement_status.status (+ expires_at = received date + Pack.validity_days, if expirable)
  → INSERT audit_log (event='submission_received' / 'status_changed')

audit-readiness view (C)  — pure SELECT, no AI:
  → requirement_status WHERE status IN (not_sent, incomplete, needs_correction)   → "missing"
  → requirement_status WHERE expires_at < now()+30d                                → "expiring soon"
  → audit_log WHERE subject_id = ?  ORDER BY created_at                            → chronological trail
```

## Schema Impact
New tables (Alembic migration). All carry `user_id` + `deleted_at` except `audit_log`.

- **`subjects`** — `id uuid pk`, `pack_id text`, `profile jsonb`, `status text`, `created_at`,
  `user_id`, `deleted_at`. *Generic compliance subject; the Pack labels it.*
- **`requirement_status`** — `id uuid pk`, `subject_id fk`, `requirement_id text` (Pack id, not
  FK), `status text` (Core lifecycle), `expires_at date null`, `completed_at null`, `updated_at`,
  `user_id`, `deleted_at`. **The heart of C.** Unique `(subject_id, requirement_id)`.
- **`submissions`** — `id uuid pk`, `subject_id fk`, `requirement_id text`, `file_ref`,
  `source text` (email/upload/in_person), `received_at`, `received_by`, `status text`, `user_id`,
  `deleted_at`. *Powers B's intake tracking. No extracted fields in the wedge.*
- **`reminders`** — `id uuid pk`, `subject_id fk`, `requirement_id text null` (null = packet-level),
  `kind text` (friendly/second/escalation), `recipient_role text`, `channel text`, `sent_at`,
  `user_id`, `deleted_at`. *Log of B's reminder engine; one row per reminder sent.*
- **`audit_log`** — `id uuid pk`, `subject_id fk`, `requirement_id text null`, `event_type text`,
  `actor text` (user_id or 'system'), `detail jsonb`, `created_at`. **Append-only, no
  soft-delete** — the WORM-lite defensibility trail (full immutable WORM store is deferred).

Indexes: `requirement_status (subject_id)`, `requirement_status (expires_at)` (for the
expiring-soon query), `submissions (subject_id, requirement_id)`, `audit_log (subject_id,
created_at)`.

- Ownership: ✅ `user_id` + `deleted_at` on all but `audit_log`.
- Provenance: N/A — no vector columns here (RAG KB for Workflow A reuses existing `VECTOR(1024)`).

## Seams & Forward-Compatibility
- **`requirement_id` as a config reference** (not a FK) is the seam that keeps requirements in
  Pack config: change the vertical's checklist by editing the Pack, no schema migration.
- **`profile jsonb`** absorbs any vertical's subject fields with zero DDL change — the anti-fork
  invariant in the data layer.
- **`expires_at` + Pack `validity_days`** is the hook the deferred **renewal engine** consumes
  later (monitor expiring rows → generate renewal tasks) — built generically now, activated later.
- **`submissions.file_ref`** is where the deferred **OCR/extraction** pipeline attaches: it will
  populate extracted-field rows and auto-set status, replacing the wedge's manual status — without
  touching these tables' shape.
- **`audit_log`** is the precursor to the full **WORM permanent store** (Repository B): same event
  trail, later mirrored to an immutable/read-only store at approval time.

## Edge Cases & Error Handling
- **Unknown `requirement_id`** (not in the active Pack): reject the write with a clear error —
  prevents drift between Pack config and stored data (the config/data join must stay consistent).
- **Pack changes after subjects exist** (a requirement added/removed): out of scope for the wedge
  — note as Open Question (reconciliation strategy). For now, requirement set is materialized at
  subject creation.
- **Duplicate submission** for a requirement: allowed (multiple files); B/C count them; dedupe/
  quality checks are the deferred OCR phase's job.
- **Soft-deleted subject**: B/C queries filter `deleted_at IS NULL`; `audit_log` rows persist
  (the trail must survive a subject's soft-delete for defensibility).

## Out of Scope for This Feature
- OCR / field extraction / scan-quality / intake-score (deferred Workflow D).
- The two-repository working-vs-permanent **WORM store** (Repository A/B) — only `audit_log` here.
- e-signature; external Live Scan / background-check / HCA-registration integrations.
- Document categorization/auto-renaming automation (Phase 9 of the client doc).
- Reconciling Pack-requirement changes against already-materialized subjects.
- Real RBAC/auth (schema-only `user_id` seam only); multi-tenancy.

## Test Plan
- **Unit**: subject creation materializes exactly the active Pack's requirement set; unknown
  `requirement_id` write is rejected; receiving a submission updates status + computes `expires_at`
  from Pack `validity_days`; every mutation appends an `audit_log` row.
- **Integration** (`httpx.AsyncClient` + test DB): create subject → record submissions → query the
  C views (missing / expiring-soon / chronological trail) return correct rows; soft-deleting a
  subject hides it from B/C but preserves its `audit_log`.
- **Boundary (CI)**: grep test confirms no vertical vocabulary in the migration DDL.

## Open Questions
- [ ] **Subject lifecycle vs. requirement statuses:** does `subjects.status` derive from its
      requirement-status rows (computed) or is it set explicitly? Lean computed for C's accuracy.
- [ ] **Where does `file_ref` point** in the wedge — local filesystem path, DB blob, or the
      existing storage path convention? (Ties to the deferred WORM store; keep it abstract now.)
- [ ] **Reminder scheduling source:** does the wedge drive reminders from n8n (reading these
      tables) or a Core scheduler? (Affects whether `reminders` is written by n8n or the engine.)
- [ ] **Pack-requirement change reconciliation** (above) — defer, but decide before the first
      real renewal cycle.
```
