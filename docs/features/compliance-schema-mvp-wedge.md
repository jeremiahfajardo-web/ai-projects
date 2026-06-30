# Feature: Compliance schema — MVP wedge (tracking, reminders, audit-readiness)

## Status
[x] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-29 — aligned to the current feature-spec template (added **Security Review**
+ standalone **Smoke Test** sections) and hardened the `audit_log` / constraint design so this spec
actually discharges the three invariants the boundary spec defers to it (no-hard-delete, full
who/why/when/what traceability, the A01 ownership filter). 2026-06-26 — initial draft. The
**minimal** generic schema behind the sellable wedge (Workflows B + C). Deliberately smaller than
the full compliance platform; grows into it without rework. Governed by
[compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md)._

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
      an **append-only audit-log** row capturing **who / why / when / what** — `actor` (the
      initiating human, AI agent, or `system`; AI actions also stamp the authorizing user + the
      trigger that fired them), `reason`, `created_at`, and the `event_type` + target
      (`subject_id`/`requirement_id`) — the defensibility trail for C's audit view. This is the
      concrete build of the boundary spec's *Full action traceability* invariant
      (`deferred → this spec`).
- [ ] The schema admits **no hard-delete path**: every owned table soft-deletes via `deleted_at`,
      and `audit_log` is append-only (app role granted `INSERT`/`SELECT` only — no `UPDATE`/`DELETE`).
      The concrete build of the boundary spec's *No hard deletes* invariant (`deferred → this spec`).
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
- **ai-database-v1** (primary): the five tables + indexes + CHECK constraints land in
  `init.sql` (postgres-owned, alongside the existing shared/audit tables like `mcp_tool_calls` and
  `error_log`), with least-privilege grants in `create_users.sh`. **Not** an Alembic migration —
  Alembic lives in the rag-client and runs as `rag_user`, which would *own* the tables and so could
  re-grant itself write access to `audit_log`, defeating the append-only guarantee. Postgres
  ownership + grant (not REVOKE) makes append-only a real privilege fact.
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
| status | enum | Core lifecycle | `not_sent / sent / opened / in_progress / returned / incomplete / needs_correction / approved / filed` — the **fixed** Core lifecycle (Pack supplies only display *labels*; boundary Resolved Decision #1), DB-enforced via `CHECK (status IN (...))` on `TEXT` (house convention — `turns.role`, `mcp_tool_calls.status` — not a native PG `ENUM` type) so values can't drift |
| `reason` | text | service / Pack rule / AI trigger | the *why* on every `audit_log` row — the human action, the Pack rule, or the trigger that fired an AI action |
| `actor` | text | `get_current_user()` / agent id / `'system'` | the *who*; AI actions also record the authorizing user + trigger in `audit_log.detail` |

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
  → INSERT audit_log (event='subject_created', actor, reason, created_at)

receive a document
  → INSERT submissions (subject_id, requirement_id, source, received_at, received_by, user_id)
  → UPDATE requirement_status.status (+ expires_at = received date + Pack.validity_days, if expirable)
  → INSERT audit_log (event='submission_received' / 'status_changed', actor, reason, created_at)

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
  FK), `status` (Core lifecycle — `TEXT` + `CHECK (status IN (...))` per house convention
  (`turns.role`, `mcp_tool_calls.status`), **not** free text and **not** a native PG `ENUM`, so the
  fixed lifecycle can't drift but stays cheap to amend), `expires_at date null`, `completed_at null`,
  `updated_at`, `user_id`, `deleted_at`.
  **The heart of C.** Uniqueness is a **partial unique index** `(subject_id, requirement_id) WHERE
  deleted_at IS NULL` — a plain `UNIQUE` would block re-materializing a requirement after a
  soft-delete.
- **`submissions`** — `id uuid pk`, `subject_id fk`, `requirement_id text`, `file_ref`,
  `source text` (email/upload/in_person), `received_at`, `received_by`, `status text`, `user_id`,
  `deleted_at`. *Powers B's intake tracking. No extracted fields in the wedge.*
- **`reminders`** — `id uuid pk`, `subject_id fk`, `requirement_id text null` (null = packet-level),
  `kind text` (friendly/second/escalation), `recipient_role text`, `channel text`, `sent_at`,
  `user_id`, `deleted_at`. *Log of B's reminder engine; one row per reminder sent.*
- **`audit_log`** — `id uuid pk`, `subject_id fk`, `requirement_id text null`, `event_type text`,
  `actor text` (the *who* — `user_id`, an AI agent id, or `'system'`), `reason text` (the *why* —
  the human action, Pack rule, or AI trigger; required, not nullable), `actor_kind text`
  (`human`/`ai`/`system`), `detail jsonb` (for AI actions: the authorizing user + the trigger that
  fired the action; plus any event-specific payload), `created_at` (the *when*). **Append-only, no
  soft-delete** — the WORM-lite defensibility trail (full immutable WORM store is deferred). The
  *what* is `event_type` + the `subject_id`/`requirement_id` target. This is the concrete
  who/why/when/what shape the boundary spec mandated ("not merely `subject_id`/`requirement_id`").

Indexes: `requirement_status (subject_id)`, partial `requirement_status (expires_at) WHERE
deleted_at IS NULL` (for the expiring-soon query; partial so soft-deleted rows don't bloat it),
`submissions (subject_id, requirement_id)`, `audit_log (subject_id, created_at)`.

- Ownership: ✅ `user_id` + `deleted_at` on all but `audit_log`.
- Provenance: N/A — no vector columns here (RAG KB for Workflow A reuses existing `VECTOR(1024)`).
- **No hard delete:** there is **no destructive `DELETE` path** in the schema or services —
  retention is by soft-delete (`deleted_at`) only. In `create_users.sh` the app roles are granted
  `SELECT`/`INSERT`/`UPDATE` (no `DELETE`) on the owned tables, and **`SELECT`/`INSERT` only on
  `audit_log`** (no `UPDATE`/`DELETE`) so the trail is append-only at the privilege level, not merely
  by convention. **This is a deliberate step beyond the existing audit tables**
  (`mcp_tool_calls`/`error_log` are app-discipline only and even carry `deleted_at`) — here
  immutability is the product. Because the tables are created in `init.sql` and **owned by
  `postgres`, not the app role**, the app role *cannot* re-grant itself `UPDATE`/`DELETE` — a
  grant (not a `REVOKE`) is therefore a genuine tamper control, which it would **not** be if the
  writing role owned the table (the reason this lives in `init.sql` rather than the rag-client's
  Alembic). A **separate privileged maintenance role** — never the app roles — is reserved for
  lawful corrections (CCPA/CPRA redaction / crypto-shred-with-tombstone), the boundary spec's open
  "lawful erasure vs. no-hard-delete" question; routine operation never touches it.

## Seams & Forward-Compatibility
- **`requirement_id` as a config reference** (not a FK) is the seam that keeps requirements in
  Pack config: change the vertical's checklist by editing the Pack, no schema migration.
- **`profile jsonb`** absorbs any vertical's subject fields with zero DDL change — the anti-fork
  invariant in the data layer.
- **`expires_at` + Pack `validity_days`** is the hook the deferred **renewal engine** consumes
  later (monitor expiring rows → generate renewal tasks) — built generically now, activated later.
- **`external_ref` (Mode A correlation) — additive seam, not yet a column.** Under the record-authority
  Mode A posture (the app is decoupled; the client's system is the source of record), a `subjects` row
  is a **retained working copy** of the client's caregiver record. To park outputs back and honour
  "client store wins on conflict," the subject needs a pointer to the client's record id — an
  `external_ref` / `source_record_id` (`TEXT`/`jsonb`, Instance-shaped). **Deferred until the
  source/sink connector is built** (Workflow B's Record-Authority subsection); additive, no rewrite.
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

## Security Review
Reviewed against [docs/security-checklist.md](../security-checklist.md). Each item is
ticked (with how), or `N/A — <why>`, or `deferred — <seam>`.

This spec is the **schema build** behind the wedge, so the items it most directly owns are the
ownership filter (A01), append-only audit logging (A09), injection-safe writes (A03), and the
fail-fast `requirement_id`/status validation (A05). It builds no LLM path itself — the engines that
read/write these tables (the B/C feature specs) carry the LLM rows — so those are `deferred` to
where the code lands.

### OWASP Top 10 (2021)
- [x] **A01 Broken Access Control** — Every owned table (`subjects`, `requirement_status`,
  `submissions`, `reminders`) carries `user_id` + `deleted_at`; reads filter `user_id = <current> AND
  deleted_at IS NULL`, writes stamp `user_id` from the single `get_current_user()` seam. Single-tenant
  today, but the seam ships now. `audit_log` is append-only and actor-attributed (no soft-delete).
- [x] **A02 Cryptographic Failures** — No secrets in this surface; DB/storage creds stay in
  Instance `.env`, never in the migration or a Pack. `file_ref` stores a path/blob id, not credentials.
- [x] **A03 Injection** — All writes are Alembic/SQLAlchemy parameterized DML; `requirement_id`,
  `status`, and `source` are validated against fixed/Pack-declared sets before insert. `profile` and
  `detail` are `jsonb` bound as parameters, never string-concatenated. No raw SQL added here (the
  pgvector exception doesn't apply — no vector columns).
- [x] **A04 Insecure Design** — *Defer features, build seams*: generic vertical-agnostic tables,
  `requirement_id`-as-config (not FK), `profile jsonb`, and the soft-delete/audit seams keep the
  deferred engines additive. Least-privilege grants per the A09 note. Responses expose only the
  fields B/C need.
- [x] **A05 Security Misconfiguration** — Writes **fail fast**: an unknown `requirement_id` (not in
  the active Pack) or an out-of-lifecycle `status` is rejected (DB enum/`CHECK` + Pack validation),
  not silently stored — preventing config/data drift that would corrupt the audit view.
- [ ] **A06 Vulnerable & Outdated Components** — `N/A — no new dependency`. Uses the existing
  Alembic/SQLAlchemy/pgvector stack; this spec adds a migration, not a package.
- [ ] **A07 Identification & Authentication Failures** — `deferred — get_current_user() seam`.
  Single-tenant, no auth in v1; `user_id` is ownership scoping, not authentication. **Tension
  inherited from the boundary spec:** the audit log's *who* is only legally meaningful once real auth
  lands — until then `actor` is the default local user. Auth is a prerequisite for audit-grade
  attribution, captured here so it isn't mistaken for done.
- [x] **A08 Software & Data Integrity Failures** — The append-only `audit_log` (privilege-enforced
  `INSERT`/`SELECT` only) is an integrity control: the defensibility trail can't be rewritten by the
  app role. No-hard-delete + soft-delete retain the record set.
- [x] **A09 Security Logging & Monitoring Failures** — This spec *is* the audit-logging build:
  who/why/when/what per state change, append-only, no hard delete. `detail`/`reason` must **never**
  contain secrets or full document contents — they record the action, not the payload.
- [ ] **A10 SSRF** — `N/A — no outbound request path`. The schema persists `file_ref` as an opaque
  reference; it fetches nothing. The intake/email connectors and the Mode-A SoR sink that *do* egress
  are the boundary spec's record-authority tools, reviewed there.

### AI / LLM-Specific (OWASP LLM Top 10, 2025)
- [ ] **LLM01 Prompt Injection** — `N/A — no prompt in this path`. Schema only; the RAG/answer path
  is Workflow A, unchanged.
- [ ] **LLM02 Sensitive Information Disclosure** — `deferred — B/C engine reads`. This spec provides
  the `user_id` scoping seam; enforcing no cross-subject leakage on read is the engine build's job.
- [ ] **LLM03 Supply Chain** — `N/A — no model or tool added`. No Pack `tools/` or provider here.
- [ ] **LLM04 Data & Model Poisoning** — `N/A — no ingest/embedding path`. Submissions store a
  `file_ref` + human-set status; nothing here becomes retrievable model context (the deferred OCR
  phase introduces extraction).
- [ ] **LLM05 Improper Output Handling** — `deferred — UI build (C dashboard)`. `profile`/Pack
  labels and audit `detail` rendered in C's view must be escaped (no `v-html`) in the client spec.
- [ ] **LLM06 Excessive Agency** — `deferred — B/C service + any Pack tool`. A future AI agent that
  writes submissions/status uses these tables; its blast radius is scoped where the tool is built —
  but this schema *forces* every such AI write to leave an attributed `audit_log` row (actor=ai +
  authorizing user + trigger), which is the accountability backstop for that agency.
- [ ] **LLM07 System Prompt Leakage** — `N/A — this spec changes no prompt`.
- [ ] **LLM08 Vector & Embedding Weaknesses** — `N/A — no new vector columns`. RAG KB reuses the
  existing `VECTOR(1024)` + provenance.
- [ ] **LLM09 Misinformation** — `N/A — no answer-generation path`.
- [ ] **LLM10 Unbounded Consumption** — `N/A — no model/tool loop`. Reminder/extraction loops are
  bounded where those engines are built.

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

## Smoke Test (user-performed, on the running stack)
A documented manual check so the live verification is traceable — green pytest is not "done" (see
CLAUDE.md). The wedge schema has no UI of its own yet (B/C are downstream specs), so this smoke runs
at the DB/migration layer against the live stack. _Runnable once the migration ships; recorded here
so the schema's proof is traceable when that slice lands._
- **Pre-reqs / config**: the five tables live in `ai-database-v1/init.sql`, which runs **only on a
  fresh data dir** — so wipe the bind-mount (`E:/Database/*`) and start the DB clean (current data is
  disposable per CLAUDE.md), then `docker compose up -d`. `PACK_ID=ca-homecare-onboarding` in
  `ai-infrastructure-v1/.env`.
- **Steps**:
  1. After a clean DB boot, `\d subjects requirement_status submissions reminders audit_log` in psql
     confirms all five tables + indexes/constraints exist; `\dp audit_log` shows `rag_user`/`mcp_user`
     hold only `arwd`-minus-`UPDATE`/`DELETE` (i.e. `SELECT`/`INSERT`) on it.
  2. Insert a `subjects` row (psql) under `pack_id=ca-homecare-onboarding`; confirm the service/trigger
     path materializes **one `requirement_status` row per requirement the Pack declares** (6 for the
     reference pack), each `status='not_sent'`, and a `subject_created` `audit_log` row with
     `actor`/`reason`/`created_at` populated.
  3. Insert a `submissions` row for `requirement_id='tb_test'`; confirm `requirement_status.status`
     advances and `expires_at` = received date + the Pack's `validity_days`, and a
     `submission_received` `audit_log` row appears.
  4. Run the three C queries (missing / expiring-soon / chronological trail) and eyeball the rows.
  5. Soft-delete the subject (`deleted_at = now()`); confirm B/C `WHERE deleted_at IS NULL` queries
     hide it **but** its `audit_log` rows persist.
- **Expected / pass criteria**: requirement set materializes exactly; status + `expires_at` compute
  correctly; every mutation left an attributed `audit_log` row; soft-delete hides from B/C but the
  trail survives.
- **Negative / fallback check**: (a) attempt to insert a `requirement_status`/`submissions` row with
  a `requirement_id` **not** in the active Pack → rejected with a clear error, nothing stored; (b)
  attempt a `DELETE`/`UPDATE` on `audit_log` as the app role → **denied by grant** (append-only
  proven at the privilege level); (c) grep the generated DDL for `caregiver`/`CDSS`/`TB`/`live scan`
  → no match.
- **Result**: _<user pastes outcome: PASS/FAIL + date when the migration ships>_

## Open Questions
- [x] **Subject lifecycle vs. requirement statuses** — _Resolved in
      [Workflow B](compliance-workflow-b-intake-tracking-reminders.md): `subjects.status` is a
      **computed rollup** of its `requirement_status` rows (not independently editable), so C can't
      drift from the checklist. The column stays (constrained), populated as a rollup._
- [x] **Where does `file_ref` point** — _Resolved in
      [Workflow B](compliance-workflow-b-intake-tracking-reminders.md): an **abstract opaque
      reference** behind a storage seam (local path under an Instance storage volume now; WORM store
      later). The schema does not assume a filesystem; `file_ref` stays `TEXT`._
- [x] **Reminder scheduling source** — _Resolved in
      [Workflow B](compliance-workflow-b-intake-tracking-reminders.md): **n8n drives the cadence**
      (default, pluggable per the boundary) but the `reminders` **write goes through a Core
      endpoint/tool**, so the table is written by the engine regardless of orchestrator._
- [ ] **Pack-requirement change reconciliation** (above) — defer, but decide before the first
      real renewal cycle. (Still open; surfaced again in Workflow C's edge cases.)
```
