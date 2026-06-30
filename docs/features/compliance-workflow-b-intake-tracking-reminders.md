# Feature: Workflow B — Intake, Tracking & Reminders

## Status
[x] Spec  [x] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-30 — **In Progress, Slice 1 (create-subject) backend built.** This feature
is being shipped in vertical slices (see [Slice Plan](#slice-plan)). **Slice 1 = AC #1/#6/#7**
(create a subject under the active Pack → materialize one `requirement_status` per declared
requirement → `subject_created` audit row, atomically): shipped as the Core MCP tool
`compliance_create_subject` (ai-mcp-server-v1 `tools/compliance.py`) + the `POST /api/subjects` BE
route that proxies it (ai-rag-llm-client-v1). Unit + route tests green (mcp-server 145, rag-client
190); **live smoke + FE pending** (BE-before-FE gate — no intake UI this slice). Slices 2–4
(submissions, transitions, reminders) not yet built._

_2026-06-29 — initial authored draft. The **write-side** wedge workflow: create a
subject, record received documents, advance requirement status, and drive reminders. Consumes the
schema from [compliance-schema-mvp-wedge.md](compliance-schema-mvp-wedge.md); governed by
[compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md). Paired
read-side is [compliance-workflow-c-audit-readiness-dashboard.md](compliance-workflow-c-audit-readiness-dashboard.md)._

## Slice Plan
B is delivered in dependency order; each slice is its own BE-before-FE build + PR:
1. **[Built on branch — unit+route tests + live smoke green] Create subject → materialize checklist +
   audit** (AC #1, #6, #7) — the write-through-Core foundation. Core tool `compliance_create_subject`
   + `POST /api/subjects`. No DB change. FE deferred (BE-before-FE). Pending merge.
2. **[ ] Record submission → advance status + `expires_at`** (AC #2, #3) — adds the additive
   `submissions.status` CHECK.
3. **[ ] Human status transitions + computed subject-status rollup** (AC #4, #6).
4. **[ ] Reminder engine + n8n cadence** (AC #5) — adds the additive `reminders.channel` CHECK.

## Problem Statement
The wedge sells on three workflows: **A** policy assistant (RAG, built), **B** intake + tracking +
reminders, **C** audit-readiness dashboard. B is where a subject's compliance packet is *worked*:
someone receives a document (by email, upload, or in person), records it against the requirement it
satisfies, the requirement's status advances, and the system nudges the right people when items are
missing or expiring. Without B there is nothing to put *into* the schema and nothing for C to report
on. B must do this **generically** — reading the active Pack's requirement list, status labels, and
reminder cadence — so a new vertical needs no B code change, only a new Pack.

## Acceptance Criteria
- [ ] **Create subject → materialize checklist.** Creating a subject under the active Pack inserts
      the subject and **one `requirement_status` row per requirement the Pack declares**
      (`status='not_sent'`), in a single transaction, and writes a `subject_created` audit row.
- [ ] **Record a submission.** A received document is recorded as a `submissions` row tied to its
      `subject_id` + Pack `requirement_id` + `source` (email/upload/in_person); the matching
      `requirement_status` advances and, if the requirement is expirable, `expires_at` is computed
      as *received date + Pack `validity_days`*. A `submission_received` (and `status_changed` when
      status moves) audit row is written.
- [ ] **Unknown `requirement_id` is rejected.** A submission or status write naming a
      `requirement_id` not declared by the active Pack fails fast with a clear error and writes
      nothing — no drift between Pack config and stored data.
- [ ] **Human status transitions.** An operator can move a requirement along the fixed Core
      lifecycle (e.g. `returned`, `needs_correction`, `approved`) with a **reason**; each transition
      writes an attributed audit row (who / why / when / what). The wedge sets status by hand — no
      OCR/auto-extraction.
- [ ] **Reminder engine.** For requirements that are due/overdue per the Pack's reminder cadence,
      the system emits a reminder (`friendly` / `second` / `escalation`) to the Pack-declared
      recipient role, logs one `reminders` row per reminder sent, and writes a `reminder_sent` audit
      row. Reminders never hard-fail the workflow if a channel is down (logged, retried per cadence).
- [ ] **Subject status is a computed rollup** (resolves schema Open Q #1): `subjects.status` is
      derived from its `requirement_status` rows (not independently editable), so C never disagrees
      with the underlying checklist. _(See Resolved Decisions.)_
- [ ] **Generic / no vertical vocabulary.** B reads requirement ids, labels, cadence, and roles from
      the active Pack; no requirement name, role, or vertical word is hard-coded in B.
- [ ] **Ownership + audit on every write.** Every write stamps `user_id` from `get_current_user()`;
      every state change appends an `audit_log` row; nothing is hard-deleted.

## Affected Repos / Surfaces
- **ai-mcp-server-v1** (primary engine): the generic intake/tracking/reminder **services + MCP
  tools** that mutate the schema through Core's enforced primitives (so the invariants hold beneath
  any orchestrator). Validates `requirement_id` against the loaded Pack (`pack_loader`).
- **ai-rag-llm-client-v1**: BE routes the UI calls (create subject, record submission, update
  status) + the **FE** intake forms and status controls (Vue). **BE-before-FE gate applies** — build
  and test the backend slice before any of this FE.
- **ai-infrastructure-v1 / ai-n8n-v1**: n8n runs the **reminder cadence orchestration** (the *when*),
  calling a Core endpoint/tool that performs the *write* (the *what*) — orchestration is pluggable
  per the boundary; invariants stay in Core, not n8n.
- **ai-database-v1**: no schema change expected (uses the five wedge tables); any tightening of
  `submissions.status` is an additive CHECK (see Schema Impact).

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| `pack_id` | text | active Pack (env) | the vertical; requirement set + cadence + roles come from it |
| `subject.profile` | jsonb | UI (Pack-defined fields) | validated against the Pack's `subject` field schema |
| `requirement_id` | text | Pack config | validated against the active Pack at write time; reject if unknown |
| `submission` | object | upload / email / in-person form | `{ requirement_id, source, file_ref, received_at, received_by }` |
| `status transition` | object | UI / engine | `{ requirement_id, to_status, reason }`; `to_status` ∈ fixed lifecycle |
| `reminder cadence` | config | Pack `reminders.yaml` | offset days, kind, recipient role, escalation target |

## Outputs / Response Shape
```json
{
  "subject": { "id": "uuid", "pack_id": "<pack>", "status": "in_progress",
               "profile": { "...": "Pack-defined" } },
  "requirements": [
    { "requirement_id": "<pack id>", "label": "<Pack label>", "status": "approved",
      "expires_at": "2027-07-01", "submission_count": 1 },
    { "requirement_id": "<pack id>", "label": "<Pack label>", "status": "not_sent",
      "expires_at": null, "submission_count": 0 }
  ]
}
```

## Data Flow
```
create subject (POST /api/subjects)
  → validate profile against Pack.subject schema
  → INSERT subjects (pack_id, profile, status='in_progress', user_id)
  → for each Pack.requirement: INSERT requirement_status (status='not_sent', user_id)
  → INSERT audit_log (subject_created, actor, reason)         [single transaction]

record submission (POST /api/subjects/{id}/submissions)
  → validate requirement_id ∈ active Pack         (reject unknown → 422)
  → INSERT submissions (subject_id, requirement_id, source, file_ref, received_by, user_id)
  → UPDATE requirement_status.status (+ expires_at = received + Pack.validity_days if expirable)
  → INSERT audit_log (submission_received [+ status_changed], actor, reason)

human status transition (PATCH /api/subjects/{id}/requirements/{rid})
  → validate to_status ∈ fixed lifecycle, requirement_id ∈ Pack
  → UPDATE requirement_status.status (+ completed_at when terminal)
  → INSERT audit_log (status_changed, actor, reason)

reminder cadence (n8n schedule → POST /api/internal/reminders/run, or Core scheduler)
  → SELECT requirement_status due/overdue per Pack.reminders cadence
  → for each: send via channel → INSERT reminders (kind, recipient_role, channel, user_id)
            → INSERT audit_log (reminder_sent, actor='system', reason='cadence:<offset>')
```

## Record Authority & Phase-1 Trigger (Mode A — decoupled)
Phase 1 ("HR enters a new hire") is an **inbound trigger from the client's system of record (SoR)**,
not an action the app originates. The app runs **decoupled** (boundary Record Authority, **Mode A —
the default + the pitch**): the client's app is the SoR; the app operates on a **retained working
copy**, performs the workflow (create subject, materialize checklist, send welcome email), and
**parks tamper-evident outputs** back for the client's systems to retain. **Their store wins on
conflict.**

Three stores, two of them swappable seam stand-ins:
- **Source connector (inbound).** Real form: the client app posts a "new-hire" event to a Pack-level
  `tools/` connector. **Demo/presentation stand-in:** a **trigger form UI** (we won't have client
  data access in a prospect meeting), standing in for that connector — swapped for the real one with
  **zero Core change**.
- **Working copy (ours, real).** The five wedge tables. **Retained, audited, no-hard-delete** — Mode
  A makes it *non-authoritative*, never *ephemeral* (boundary: traceability over ephemerality).
- **SoR sink (outbound).** A *park/sink* `tools/` tool writes tamper-evident outputs to the client
  SoR (allowlisted endpoint — A10/SSRF; every write stamped to `audit_log`). **Demo stand-in:** a
  **mock SoR store** representing their official data store, the park destination during a
  presentation — swapped for the real endpoint later.

Invariants that keep this from becoming a fork:
- **Custom Python *and* n8n both ride the same MCP tools, through Core's enforced primitives** —
  never straight to the DB or the client SoR. Per boundary Resolved Decision #5, **custom/agentic code
  is always a Pack `tools/`/runner plugin** (reviewed catalog, `requires_core`-pinned), **even for a
  single customer**. The **Instance stays declarative** (config, secrets, content) — *no per-customer
  bespoke code overlay*. This is the line that keeps "custom flows per client" from re-becoming
  fork-per-customer.
- **Correlation:** each working-copy subject carries an **`external_ref`** back to the client's SoR
  record (schema seam, deferred) so parked outputs reconcile to their system.
- **Open posture call:** the source doc's "permanent compliance file, ready for CDSS inspection"
  leans **Mode B (we hold custody)**; Mode A means we hold a working copy + parked outputs sufficient
  to *render* the audit view while the authoritative packet is **theirs**. Which one per vertical is
  the boundary's open "default posture" question — decide before a real deployment; the demo should
  not implicitly promise custody.

## Schema Impact
Uses the five wedge tables as built — **no new tables**. Two additive refinements this spec owns
(left open by the schema spec):
- **`submissions.status`** vocabulary: `received / accepted / rejected` — add as a `CHECK` once
  confirmed (additive; default `received`). Disposition only; the authoritative requirement state is
  `requirement_status.status`.
- **`reminders.channel`** vocabulary: `email / sms / in_app` — add as a `CHECK` (additive). The wedge
  ships **email** first.
- **`subjects.external_ref`** (Mode A correlation): an additive `TEXT`/`jsonb` pointer to the client
  SoR record, added when the source/sink connector lands (see Record Authority above). Not needed for
  the trigger-form demo; required before a real SoR integration.
- Ownership: ✅ all writes stamp `user_id`; reads filter `deleted_at IS NULL`.
- No hard delete: status corrections are soft transitions; nothing is `DELETE`d.

## Seams & Forward-Compatibility
- **Status set by a human now; OCR later.** `submissions.file_ref` + manual status is the seam the
  deferred **OCR/extraction** engine replaces — it will auto-populate extracted fields and set status
  without changing B's table writes.
- **Reminder orchestration is pluggable.** n8n drives the *cadence* (default), but the *write* goes
  through a Core tool/endpoint, so swapping n8n for a custom-code runner (boundary Orchestration
  seam) needs no B change and can't bypass the audit/no-hard-delete invariants.
- **`file_ref` is abstract** (resolves schema Open Q #2): B stores an opaque reference; the physical
  store (local path under an Instance storage volume now; WORM store later) sits behind a storage
  seam, Instance-configured. B does not assume a filesystem.
- **Reminder source** (resolves schema Open Q #3): n8n (declarative, default) over a Core write
  endpoint; a Core scheduler is the fallback backend — same `reminders` write path either way.

## Edge Cases & Error Handling
- **Unknown `requirement_id`**: `422`, nothing written (config/data drift guard).
- **Invalid `to_status`** (not in the fixed lifecycle): `422` (DB CHECK is the backstop).
- **Duplicate submission for a requirement**: allowed (multiple files); counted, not deduped — dedupe
  is the deferred OCR phase's job.
- **Submission for an already-approved requirement**: allowed but flagged; status does not regress
  unless an operator explicitly transitions it (with a reason).
- **Reminder channel failure** (e.g. SMTP down): logged as an error, the workflow does not crash; the
  cadence retries on its next run. No `reminders` row is written for a send that failed.
- **Subject soft-deleted mid-packet**: B writes stop (filtered out); existing `audit_log` rows
  persist.

## Security Review
Reviewed against [docs/security-checklist.md](../security-checklist.md). Each item is
ticked (with how), or `N/A — <why>`, or `deferred — <seam>`.

### OWASP Top 10 (2021)
- [ ] **A01 Broken Access Control** — All reads filter `user_id` + `deleted_at IS NULL`; all writes
  stamp `user_id` from the single `get_current_user()` seam. Single-tenant today; the filter ships.
- [ ] **A02 Cryptographic Failures** — No secrets in B code; mailbox/SMTP creds + storage paths are
  Instance `.env`, never logged.
- [ ] **A03 Injection** — Parameterized writes throughout; `requirement_id`/`to_status` validated
  against the Pack + the fixed lifecycle before any DML; `profile` bound as `jsonb`.
- [ ] **A04 Insecure Design** — Writes go through Core primitives (not n8n→DB directly), so the
  audit + no-hard-delete invariants can't be bypassed by the orchestrator (boundary rule).
- [ ] **A05 Security Misconfiguration** — Unknown `requirement_id` / bad status fail fast (`422` +
  DB CHECK); the reminder runner endpoint is internal-only (not publicly routable).
- [ ] **A06 Vulnerable & Outdated Components** — Any new email/SMTP client is pinned + reviewed;
  flag in this spec when added.
- [ ] **A07 Identification & Authentication Failures** — `deferred — get_current_user() seam`. The
  *who* on status transitions is the default local user until real auth; audit attribution is
  audit-grade only once auth lands (inherited from boundary A07).
- [ ] **A08 Software & Data Integrity Failures** — Writes ride Core's enforced tools; `audit_log` is
  append-only (privilege-enforced, schema spec). An orchestrator runner cannot reach around them.
- [ ] **A09 Security Logging & Monitoring Failures** — Every mutation appends an attributed
  `audit_log` row (who/why/when/what); never log file contents or creds in `detail`/`reason`.
- [ ] **A10 SSRF** — `deferred — email/SoR sink review`. Outbound is reminder **email** (SMTP to a
  configured server, not arbitrary URL fetch); an email-intake fetch or a Mode-A SoR sink that
  egresses must be allowlisted + reject internal/metadata targets when built.

### AI / LLM-Specific (OWASP LLM Top 10, 2025)
- [ ] **LLM01 Prompt Injection** — `N/A — no LLM in B's path`. The wedge sets status by hand; no
  document content reaches a model here (that's the deferred OCR phase + Workflow A).
- [ ] **LLM02 Sensitive Information Disclosure** — `deferred — user_id scoping (above)`. No
  cross-subject read; submissions/audit are subject-scoped.
- [ ] **LLM03 Supply Chain** — `N/A — no model/tool added here` beyond Pack `tools/` (governed by
  the boundary's reviewed-catalog rule).
- [ ] **LLM04 Data & Model Poisoning** — `N/A — no ingest/embedding in B`. Uploaded files are stored
  as references, not embedded (OCR/ingest is deferred).
- [ ] **LLM05 Improper Output Handling** — `deferred — FE slice`. The intake UI renders Pack labels +
  user-entered profile/filenames; escape them (no `v-html`) in the client.
- [ ] **LLM06 Excessive Agency** — A future AI agent that records submissions/advances status would
  act through B's tools; **this spec forces every such write to leave an attributed audit row**
  (`actor_kind='ai'` + authorizing user + trigger), bounding the agency. No autonomous status change
  in the wedge.
- [ ] **LLM07 System Prompt Leakage** — `N/A — B changes no prompt`.
- [ ] **LLM08 Vector & Embedding Weaknesses** — `N/A — no vectors in B`.
- [ ] **LLM09 Misinformation** — `N/A — no generated answers in B`.
- [ ] **LLM10 Unbounded Consumption** — The reminder runner is bounded (one pass per cadence tick,
  one row per due item); no model loop.

## Out of Scope for This Feature
- OCR / field extraction / scan-quality / auto-status (deferred Workflow D).
- The audit-readiness **dashboard / views** — that is Workflow C (the read side).
- e-signature; external Live Scan / background-check / registry integrations.
- Pack-requirement change reconciliation against already-materialized subjects (schema Open Q).
- Real RBAC/auth; multi-tenancy.
- The WORM permanent store + audit export (only `audit_log` exists in the wedge).

## Test Plan
- **Unit** (mock DB + Pack): create-subject materializes exactly the Pack's requirement set; unknown
  `requirement_id` rejected; submission computes `expires_at` from `validity_days`; each mutation
  appends an audit row; subject status rollup is computed, not stored independently.
- **Integration** (`httpx.AsyncClient` + test DB + loaded reference Pack): create → submit → transition
  → reminder-run; assert rows, audit trail, and that an unknown requirement writes nothing.
- **Frontend** (Vitest): intake form validates against Pack fields; status control disables illegal
  transitions; renders Pack labels (escaped).

## Smoke Test (user-performed, on the running stack)
- **Pre-reqs / config**: stack up; `PACK_ID=ca-homecare-onboarding`; the wedge schema present (clean
  DB boot, schema spec smoke passed); SMTP (or a dev mailcatcher) configured in `.env`.
- **Steps**:
  1. Create a subject via the UI/endpoint; confirm the requirement checklist materializes (count =
     Pack requirements) and a `subject_created` audit row exists.
  2. Record a submission for an expirable requirement; confirm status advances, `expires_at` is set,
     and audit rows appear.
  3. Transition a requirement to `needs_correction` with a reason; confirm the audit row carries the
     reason + actor.
  4. Trigger the reminder run for a `not_sent` item past its first offset; confirm a `reminders` row +
     `reminder_sent` audit row + the email lands in the catcher.
- **Expected / pass criteria**: all of the above with **Pack-supplied** labels/roles, no code change;
  subject status reads as a rollup of its requirements.
- **Negative / fallback check**: submit an unknown `requirement_id` → `422`, nothing written; stop SMTP
  and run reminders → logged error, workflow survives, no false `reminders` row.
- **Result**: **Slice 1 (create-subject) — PASS, 2026-06-30** (clean rebuild: wiped `E:/Database`,
  rebuilt all images, fresh `init.sql`). `POST /api/subjects` with a Caregiver profile under
  `PACK_ID=ca-homecare-onboarding` → `200`, materialized **exactly 43 `requirement_status` rows**
  (= Pack requirement count), all `not_sent`, + one attributed `subject_created` `audit_log` row
  (`actor_kind=human`, reason, `detail={pack_id, requirement_count:43}`). Negatives: unknown profile
  field and missing-required-field both → **`422`, nothing written** (subjects count unchanged);
  `rag_user` `DELETE FROM audit_log` → **permission denied** (append-only holds at the privilege
  level). _Steps 2–4 (submission/transition/reminder) pending their slices._ A fresh-boot fix was
  needed en route — see note below. _<remaining steps fill as slices 2–4 ship>_

> **Fresh-boot fix (shipped with Slice 1, ai-mcp-server-v1):** the clean rebuild surfaced a latent
> first-run bug — the MCP server's corpus-provenance self-check (`config_check.py`) queried
> `document_chunks` (a rag-client Alembic-owned table) and crashed boot with `UndefinedTableError`
> on a brand-new DB, because the rag-client's migrations run *after* the MCP server boots. The check
> now treats a not-yet-created corpus table as empty. This is a real bug for the "downloadable
> truly-local intro app" first-run path, masked until the DB was wiped. Covered by a regression test.

## Open Questions
- [ ] **Email intake mechanics** — how received-by-email documents reach B (a polled mailbox via n8n
      vs. a forwarding address parsed by a Core tool); ties to A10/SSRF review.
- [ ] **Escalation recipients** — when `escalation` fires, is the target a Pack role resolved to a
      real account (needs the auth seam) or a static Instance address until auth lands?
- [ ] **Reminder idempotency** — keying so a cadence re-run doesn't double-send (e.g. unique
      `(subject_id, requirement_id, kind, offset)` per cycle).
- [ ] **Status regression policy** — exact rules for when an `approved` item may move back (operator
      override only, with reason — confirm).
- [ ] **Record-authority posture (Mode A vs B)** for the inspection-ready permanent file — who holds
      the authoritative packet (theirs vs us). Pairs with the boundary's open "default posture per
      vertical" question; decide before a real deployment (the demo runs Mode A with stand-ins).
- [ ] **Demo harness scope** — how faithfully the presentation trigger-form + mock SoR mimic a real
      inbound event / park target, so the demo→production swap to real `tools/` connectors stays a
      drop-in (no Core change).
