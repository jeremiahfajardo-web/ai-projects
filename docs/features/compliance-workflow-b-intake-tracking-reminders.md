# Feature: Workflow B — Intake, Tracking & Reminders

## Status
[x] Spec  [x] In Progress  [x] Testing  [x] Done

_Last updated: 2026-07-01 — **DONE. All four slices shipped; live smoke green.** Slice 4
(reminder engine, AC #5) ships the Core tool `compliance_run_reminders` (ai-mcp-server-v1): one
cadence pass over open packets that, for each subject whose gating requirements are still
outstanding, sends any **due** reminder per the active Pack's `reminders.yaml` — a step is due when
`today >= subject.created_at + offset_days` (the **intake clock**, the wedge's reference in lieu of a
stored packet due date; see [Resolved Decisions](#resolved-decisions)). Each send emails a single
Instance mailbox (`REMINDER_TO`, roles recorded but unresolved until the auth seam), writes one
packet-level `reminders` row (`channel='email'`) + one attributed `reminder_sent` audit row, and is
**idempotent** (at most one live reminder per `kind` per subject). A down channel logs + skips (no
row), never crashing the run. Orchestration is the new **n8n workflow C** (`Schedule → the MCP tool`)
+ a bundled **MailHog** catcher. DB: the additive `reminders.channel` CHECK (`email/sms/in_app`).
Tests: mcp-server **177** (7 new). **Live smoke PASS 2026-07-01** (see Smoke Test). This closes
Workflow B — every Acceptance Criterion + Security Review item is now accounted for below._

_2026-06-30 — Slices 1–3 shipped (BE+FE), live smoke green. **Slice 3 = AC #4/#6**
(human status transitions + computed subject-status rollup): Core tool
`compliance_transition_requirement` (ai-mcp-server-v1) moves a requirement along the fixed Core
lifecycle **with a required reason**, stamping `completed_at` on terminal states and writing an
attributed `status_changed` audit row; every requirement change (transition **and** submission,
retrofitted; and subject creation) now recomputes `subjects.status` as the **weakest-link rollup over
the Pack's completion gates** (see [Resolved Decisions](#resolved-decisions)), writing a
`subject_status_rollup` audit row when it moves. BE: `PATCH /api/subjects/{id}/requirements/{rid}`
proxy; `GET /pack` now also exposes the Core `lifecycle` + Pack `status_labels` + `completion_gates`.
FE: an inline per-row status control (Pack-labelled dropdown + required reason) on the intake
checklist + a packet-status pill. Tests green (mcp-server 170, rag-client 213 unit, frontend 30
Vitest); **live smoke PASS 2026-06-30** (see Smoke Test). Slice 4 (reminders) not yet built._

_2026-06-30 — Slices 1–2 shipped (BE+FE), live smoke green. Slice 1 (create-subject) = AC #1/#6/#7
via `compliance_create_subject` + `POST /api/subjects` + a generic Pack-driven intake UI. Slice 2
(record-submission) = AC #2/#3 via `compliance_record_submission` + `POST /api/subjects/{id}/submissions`
+ inline "Record" control; added the additive `submissions.status` CHECK._

_2026-06-29 — initial authored draft. The **write-side** wedge workflow: create a
subject, record received documents, advance requirement status, and drive reminders. Consumes the
schema from [compliance-schema-mvp-wedge.md](compliance-schema-mvp-wedge.md); governed by
[compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md). Paired
read-side is [compliance-workflow-c-audit-readiness-dashboard.md](compliance-workflow-c-audit-readiness-dashboard.md)._

## Slice Plan
B is delivered in dependency order; each slice is its own BE-before-FE build + PR:
1. **[DONE — BE+FE merged, live smoke green] Create subject → materialize checklist + audit**
   (AC #1, #6, #7) — the write-through-Core foundation. Core tool `compliance_create_subject` +
   `POST /api/subjects`; intake **FE** is a generic Vue form rendered from the active Pack's
   `subject_fields` (new `GET /api/pack` proxy + `introspection.subject_fields`), `/intake` route.
   No DB change.
2. **[DONE — BE+FE merged, live smoke green] Record submission → advance status + `expires_at`**
   (AC #2, #3) — Core tool `compliance_record_submission` + `POST /api/subjects/{id}/submissions`;
   inline "Record" control on the intake checklist (records against the just-created subject —
   loading an existing subject by id is Workflow C). Adds the additive `submissions.status`
   CHECK (`received/accepted/rejected`, default `received`) in ai-database-v1. A submission moves a
   requirement from a pre-receipt state to `in_progress` (never regresses a later state), sets
   `expires_at = received + Pack validity_days` for expirable items, and writes
   `submission_received` (+ `status_changed` when it moves) audit rows.
3. **[DONE — BE+FE merged, live smoke green] Human status transitions + computed subject-status
   rollup** (AC #4, #6) — Core tool `compliance_transition_requirement` (fixed-lifecycle move with a
   required reason, `completed_at` on terminal states, attributed `status_changed` audit) +
   `PATCH /api/subjects/{id}/requirements/{rid}`; inline Pack-labelled status control + packet-status
   pill on the checklist. `subjects.status` is now a **weakest-link rollup over the Pack completion
   gates** ([Resolved Decisions](#resolved-decisions)), recomputed on every requirement change
   (transition + submission-retrofit + at creation), writing a `subject_status_rollup` audit row when
   it moves. `GET /pack` also exposes `lifecycle`/`status_labels`/`completion_gates`. No DB change.
4. **[DONE — BE + n8n merged, live smoke green] Reminder engine + n8n cadence** (AC #5) — Core tool
   `compliance_run_reminders` (ai-mcp-server-v1): one cadence pass over open packets sends any **due**
   reminder per the active Pack's cadence, keyed to the **intake clock** (`created_at + offset_days`),
   to a single Instance mailbox; logs a packet-level `reminders` row + attributed `reminder_sent`
   audit row per send; **idempotent** per `(subject, kind)`; a down channel logs + skips (no row).
   Orchestration = **n8n workflow C** (`Schedule → the MCP tool`); a bundled **MailHog** catcher +
   SMTP settings land in ai-infrastructure-v1. Adds the additive `reminders.channel` CHECK
   (`email/sms/in_app`) in ai-database-v1. **No FE** (background cadence, no UI surface). No
   rag-client change — n8n rides the MCP tool directly (boundary: orchestrators use Core tools).

## Problem Statement
The wedge sells on three workflows: **A** policy assistant (RAG, built), **B** intake + tracking +
reminders, **C** audit-readiness dashboard. B is where a subject's compliance packet is *worked*:
someone receives a document (by email, upload, or in person), records it against the requirement it
satisfies, the requirement's status advances, and the system nudges the right people when items are
missing or expiring. Without B there is nothing to put *into* the schema and nothing for C to report
on. B must do this **generically** — reading the active Pack's requirement list, status labels, and
reminder cadence — so a new vertical needs no B code change, only a new Pack.

## Acceptance Criteria
- [x] **Create subject → materialize checklist.** _(Slice 1.)_ Creating a subject under the active
      Pack inserts the subject and **one `requirement_status` row per requirement the Pack declares**
      (`status='not_sent'`), in a single transaction, and writes a `subject_created` audit row.
- [x] **Record a submission.** _(Slice 2.)_ A received document is recorded as a `submissions` row tied to its
      `subject_id` + Pack `requirement_id` + `source` (email/upload/in_person); the matching
      `requirement_status` advances and, if the requirement is expirable, `expires_at` is computed
      as *received date + Pack `validity_days`*. A `submission_received` (and `status_changed` when
      status moves) audit row is written.
- [x] **Unknown `requirement_id` is rejected.** _(Slices 2–3.)_ A submission or status write naming a
      `requirement_id` not declared by the active Pack fails fast (`422`, `RequirementValidationError`)
      and writes nothing — no drift between Pack config and stored data.
- [x] **Human status transitions.** _(Slice 3.)_ An operator can move a requirement along the fixed
      Core lifecycle (e.g. `returned`, `needs_correction`, `approved`) with a **reason**; each
      transition writes an attributed audit row (who / why / when / what). The wedge sets status by
      hand — no OCR/auto-extraction. Shipped as `compliance_transition_requirement` /
      `PATCH /api/subjects/{id}/requirements/{rid}`: reason is required (`422` if blank), `to_status`
      is validated against `CORE_LIFECYCLE` (`422` on an unknown state), terminal states stamp
      `completed_at` (cleared when a requirement is bounced back).
- [x] **Reminder engine.** _(Slice 4.)_ For packets with outstanding gating items due/overdue per the
      Pack's reminder cadence, the system emits a reminder (`friendly` / `second` / `escalation`),
      recording the Pack-declared recipient role, logs one `reminders` row per reminder sent, and writes
      a `reminder_sent` audit row. Reminders never hard-fail the workflow if a channel is down (logged,
      no row written, retried next cadence tick). Shipped as `compliance_run_reminders` + n8n workflow
      C. _Note: the reference Pack declares a **packet-level** cadence (no per-requirement offsets), so
      reminders are packet-level (`requirement_id` NULL) — "for requirements that are due" is realized
      as "for a packet with due, still-outstanding requirements" (see
      [Resolved Decisions](#resolved-decisions)); a Pack that later declares per-requirement cadence is
      a Pack change the engine reads generically. Kinds map from the Pack's richer `action` labels
      (`second_notice`/`due` → `second`)._
- [x] **Subject status is a computed rollup** _(Slice 3; resolves schema Open Q #1)_:
      `subjects.status` is derived from its `requirement_status` rows (not independently editable), so
      C never disagrees with the underlying checklist. Implemented as the **weakest-link rollup over
      the Pack completion gates** (see [Resolved Decisions](#resolved-decisions)) and recomputed on
      every requirement change — at subject creation, on submission receipt (retrofit into Slice 2's
      tool), and on a human transition — writing a `subject_status_rollup` audit row when it moves. No
      route sets `subjects.status` directly.
- [x] **Generic / no vertical vocabulary.** _(All slices.)_ B reads requirement ids, labels, cadence,
      status labels, and roles from the active Pack; no requirement name, role, or vertical word is
      hard-coded in B. Verified in smoke: the reminder emails carried **Pack-supplied** labels/roles
      (`CA Home-Care Caregiver Onboarding`, `Caregiver`) with no B code change.
- [x] **Ownership + audit on every write.** _(All slices.)_ Every write stamps `user_id` from the
      `get_current_user()` seam (reminders included: `actor_kind='system'`, actor = authorizing user);
      every state change appends an `audit_log` row (`subject_created` / `submission_received` /
      `status_changed` / `subject_status_rollup` / `reminder_sent`); nothing is hard-deleted, and the
      append-only `audit_log` privilege holds (verified across slices).

## Resolved Decisions
- **Subject-status rollup rule (AC #6) = weakest link over the completion gates** _(Slice 3)_. The
  Core lifecycle is an ordered progression (`not_sent < sent < opened < in_progress < returned <
  incomplete < needs_correction < approved < filed`). `subjects.status` is the **least-advanced
  status among the subject's *gating* requirements**: the Pack's `workflow.completion_gates` when
  declared, else every `required` requirement, else all requirements. Rationale: a packet is "ready"
  only when its furthest-behind *blocker* is — non-gating items (acknowledgements, training modules)
  track to completion but don't hold the packet's headline status back, and an attention state on a
  gate (`needs_correction`) correctly out-ranks a plain `in_progress` so the packet surfaces the
  problem. Consequences: a fresh subject reads `not_sent` (all gates unsent), not the DB default
  `in_progress`; the subject reaches `approved`/`filed` only once **every** gate does. The rollup is
  computed by Core on every requirement-status change and is never settable directly by a route
  (chosen over "gates-approved ⇒ approved" two-state and "weakest over *all* requirements"
  alternatives, which either hid intermediate states or let non-gating items block the headline).
- **Reminder timing basis = the intake clock (`created_at + offset_days`)** _(Slice 4)_. The Pack
  cadence offsets presuppose a reference date, but the wedge schema stores no packet/requirement due
  date. The wedge measures offsets from `subject.created_at` (a step is due when `today >= created_at
  + offset_days`): simple, deterministic, demoable, and enough to drive the cadence off a real event
  (intake). A stored **packet due date** (offsets as "before/after due") is the forward seam when a
  vertical needs it — no engine rewrite, just a due-date field the offset arithmetic reads instead.
- **Reminders are packet-level (`requirement_id` NULL)** _(Slice 4)_. The reference Pack authors a
  single per-*packet* cadence (its `reminders.yaml` names no requirement), and the schema already
  models `requirement_id NULL = a packet-level reminder`. So the engine sends one reminder per due
  cadence step per subject while the packet has any outstanding gating requirement — not one per
  requirement. A Pack that later declares per-requirement offsets is a Pack change the generic engine
  reads without code change.
- **Recipient resolution = a single Instance mailbox until auth** _(Slice 4)_. With no user directory,
  Pack roles can't resolve to accounts; every reminder delivers to one configured mailbox
  (`REMINDER_TO`), while the **Pack role is still recorded** on the `reminders` + audit rows — so
  role→account routing becomes real with zero engine change once the `get_current_user()`/auth seam
  lands (resolves Open Q "escalation recipients" for the wedge; the real-account form stays deferred).
- **Idempotency = one live reminder per `(subject, kind)`** _(Slice 4)_. A cadence re-run (or two Pack
  steps mapping to the same Core `kind`) sends once — the engine skips a step whose `kind` already has
  a live `reminders` row for the subject (resolves Open Q "reminder idempotency" at the app layer; a
  DB partial-unique index is the harder backstop seam). Consequence: distinct Pack actions collapsed to
  one `kind` (e.g. `second_notice` + `due` → `second`) send once, whichever comes due first.
- **Send-before-persist** _(Slice 4)_. The email is sent *before* the `reminders`/audit rows are
  written, so a failed send leaves **no** `reminders` row (AC #5 / edge case) — the cadence retries it
  next tick. A failure after a successful send (rare) is accepted: the reminder went out; the log lags.

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
- **`reminders.channel`** vocabulary: `email / sms / in_app` — added as a `CHECK` (additive, Slice 4).
  The wedge ships **email** first; `sms`/`in_app` are seamed. Verified in smoke (a bad channel is
  rejected).
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
- [x] **A01 Broken Access Control** — All reads filter `deleted_at IS NULL`; all writes stamp
  `user_id` from the single `get_current_user()`/`X-User-ID` seam (reminders included). Compliance
  tools **reject an identity-less call** (`_require_identity` → error) rather than writing under a
  silent default. Single-tenant today; the ownership filter ships.
- [x] **A02 Cryptographic Failures** — No secrets in B code; SMTP creds (`SMTP_USERNAME`/`_PASSWORD`)
  + mailbox are Instance `.env`. `notifications.send_email` logs the recipient + subject only —
  **never** the body or any credential.
- [x] **A03 Injection** — Parameterized writes throughout (reminder inserts bind `$1..$n`);
  `requirement_id`/`to_status` validated against the Pack + fixed lifecycle before any DML; `profile`
  bound as `jsonb`; email subject/body are internally composed from Pack labels (no untrusted
  header/CRLF injection surface — recipient is a fixed Instance setting, not user input).
- [x] **A04 Insecure Design** — Writes (reminders too) go through Core primitives, not n8n→DB
  directly, so the audit + no-hard-delete invariants can't be bypassed by the orchestrator (n8n
  workflow C calls the MCP tool; the boundary rule holds).
- [x] **A05 Security Misconfiguration** — Unknown `requirement_id` / bad status fail fast (`422` +
  DB CHECK, incl. the new `reminders.channel` CHECK); the reminder tool requires the MCP API key +
  identity and is not a public webhook. An unset `SMTP_HOST` degrades safely (channel off), not open.
- [x] **A06 Vulnerable & Outdated Components** — **No new dependency**: email uses the Python
  **stdlib** `smtplib`/`email` (run off-loop via `asyncio.to_thread`); MailHog is a dev-only,
  demo-scoped catcher (not a production relay). Nothing new to pin.
- [x] **A07 Identification & Authentication Failures** — `deferred — get_current_user() seam`. The
  *who* is the default local user until real auth; the reminder actor is `actor_kind='system'` with
  the authorizing user recorded. Role→account resolution is likewise deferred (single mailbox now);
  audit attribution is audit-grade only once auth lands (inherited from boundary A07).
- [x] **A08 Software & Data Integrity Failures** — Reminder writes ride Core's enforced tools;
  `audit_log` is append-only (privilege-enforced — re-verified in smoke: `rag_user DELETE` denied
  across slices). An orchestrator runner cannot reach around them.
- [x] **A09 Security Logging & Monitoring Failures** — Every mutation appends an attributed
  `audit_log` row (who/why/when/what); `reminder_sent` carries `cadence:<offset>` + action/kind/
  recipient in `detail`. Never logs file contents, message bodies, or creds in `detail`/`reason`.
- [x] **A10 SSRF** — Outbound is reminder **email** to a **configured SMTP host** (`SMTP_HOST`, an
  operator setting — not a URL derived from user/document input), so there is no attacker-controlled
  fetch target here. `deferred — email/SoR sink review`: a future email-*intake* fetch or a Mode-A SoR
  sink that egresses must be allowlisted + reject internal/metadata targets when built.

### AI / LLM-Specific (OWASP LLM Top 10, 2025)
- [x] **LLM01 Prompt Injection** — `N/A — no LLM in B's path`. The wedge sets status by hand and the
  reminder engine composes emails from Pack labels; no document content reaches a model here (that's
  the deferred OCR phase + Workflow A).
- [x] **LLM02 Sensitive Information Disclosure** — `deferred — user_id scoping (above)`. No
  cross-subject read; the reminder pass reads only the target subject(s) and its own requirement rows;
  submissions/audit are subject-scoped.
- [x] **LLM03 Supply Chain** — `N/A — no model/tool added here` beyond Pack `tools/` (governed by the
  boundary's reviewed-catalog rule). Slice 4 adds only stdlib email + a dev MailHog image.
- [x] **LLM04 Data & Model Poisoning** — `N/A — no ingest/embedding in B`. Uploaded files are stored
  as references, not embedded (OCR/ingest is deferred).
- [x] **LLM05 Improper Output Handling** — Slice 4 has **no FE surface** (background cadence); email
  bodies are plaintext (`msg.set_content`, not HTML). The intake/status **FE** (Slices 1/3) renders
  Pack labels + user-entered profile/filenames with Vue text interpolation (no `v-html`).
- [x] **LLM06 Excessive Agency** — The reminder runner acts autonomously *on a schedule* but its
  agency is bounded: it only **sends notifications + logs** (no status mutation), each send leaves an
  attributed `reminder_sent` audit row (`actor_kind='system'` + authorizing user + `cadence:<offset>`
  trigger), and it is idempotent. A future AI agent recording submissions/advancing status would ride
  the same audited tools. No autonomous *status* change in the wedge.
- [x] **LLM07 System Prompt Leakage** — `N/A — B changes no prompt`.
- [x] **LLM08 Vector & Embedding Weaknesses** — `N/A — no vectors in B`.
- [x] **LLM09 Misinformation** — `N/A — no generated answers in B`.
- [x] **LLM10 Unbounded Consumption** — The reminder runner is bounded: one pass per cadence tick, at
  most one send per `(subject, kind)` (idempotency), one `reminders`/audit row per send; no model loop.

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
  level). **Intake FE (added 2026-06-30):** `/intake` renders a generic Vue form from the active
  Pack's `subject_fields` (Caregiver: 8 fields), posts `POST /api/subjects`, and shows the
  materialized 43-item checklist; verified live through its real endpoints (`GET /api/pack` exposes
  `subject_fields`; create returns the checklist; bad profile → `422`) + the store's Vitest unit
  tests — a browser DOM click-through was not automated (no headless browser available).
  **Step 2 (record submission) — Slice 2, PASS 2026-06-30** (fresh rebuild incl. the new
  `submissions.status` CHECK): recorded a submission for `tb_test` (expirable 365d) → requirement
  advanced `not_sent → in_progress`, `expires_at = 2027-06-30`, submission `received`, audit rows
  `submission_received` + `status_changed`; a non-expirable item (`i9`) → `in_progress`/no expiry;
  duplicate submission allowed (count → 2). Negatives: unknown requirement → `422`, bad source →
  `422`, missing subject → `404`, all writing nothing. A fresh-boot fix was needed en route — see
  note below.
  **Step 3 (human status transitions + rollup) — Slice 3, PASS 2026-06-30** (rebuilt MCP + rag-client
  images; no schema change): through the real rag-client API (`:8000`, `PACK_ID=ca-homecare-onboarding`).
  `GET /api/pack` now returns the Core `lifecycle` (9 states), Pack `status_labels`, and the 8
  `completion_gates`. A freshly created subject rolled up to **`not_sent`** (all gates unsent — not the
  DB default). `PATCH .../requirements/tb_test → approved` (reason "TB clearance verified by RN"):
  requirement `approved`, subject **stayed `not_sent`** (7 gates still unsent — weakest link).
  Approving the remaining 7 gates one-by-one left the subject `not_sent` until the **last** gate → then
  **`approved`**. Bouncing `i9 → needs_correction` dragged the subject rollup to **`needs_correction`**
  (attention state out-ranks approved). DB verification: **9 `status_changed` (human)** + **1
  `subject_created`** + **2 `subject_status_rollup` (system)** audit rows; `subjects.status =
  needs_correction`; `completed_at` **set** on the `approved` gates and **cleared** on the bounced
  `i9`; rollup audit `detail` carried `{from,to,trigger,requirement_id}`. Negatives: bad `to_status`
  → `422`, empty reason → `422`, unknown requirement → `422`, missing subject → `404`, all writing
  nothing; `rag_user DELETE FROM audit_log` → **permission denied** (append-only holds). **Transition
  FE (added 2026-06-30):** the intake checklist gained an inline per-row status control (Pack-labelled
  lifecycle dropdown + required-reason input, "Set status" disabled until a reason is typed) and a
  packet-status pill reflecting the rollup; verified via the store's Vitest unit tests (15) + a green
  `vite build` + the real endpoints above — a browser DOM click-through was not automated (no headless
  browser available).
  **Step 4 (reminder engine) — Slice 4, PASS 2026-07-01** (rebuilt the MCP image to bake the new
  code; started the bundled **MailHog** catcher; recreated the MCP server with the new SMTP env —
  `SMTP_HOST=mailhog`, `REMINDER_TO=compliance-inbox@localhost`, `PACK_ID=ca-homecare-onboarding`).
  `GET /tools` now lists `compliance_run_reminders`. Created a fresh Caregiver subject (43-item
  checklist, `not_sent`) and called `compliance_run_reminders` scoped to it: **2 reminders sent** —
  `friendly` (offset −7) + `second` (from `second_notice`, −2); the `due` step (0, also → `second`)
  was **idempotently skipped** and `escalation` (+7) was **not due** (intake clock). DB verification:
  **2 `reminders` rows** (`kind` friendly/second, `recipient_role=Caregiver`, `channel=email`,
  `requirement_id` NULL = packet-level, `user_id` stamped) + **2 attributed `reminder_sent` audit
  rows** (`actor_kind=system`, `reason=cadence:−7`/`cadence:−2`, `detail` carrying action/kind/offset/
  recipient). **MailHog captured both emails** with **Pack-supplied** labels
  (`[CA Home-Care Caregiver Onboarding] … reminder`, role `Caregiver`) → `compliance-inbox@localhost`
  — no B code change. Idempotency: a **re-run sent nothing** (`sent: []`). Negatives: **channel down**
  (stopped MailHog, fresh subject) → run returned **3 errors, `sent: []`, 0 `reminders` rows**, the
  pass **survived** (no crash, no false row); the additive **`reminders.channel` CHECK rejects** a bad
  channel (`carrier_pigeon` → `check_violation`). Bad `subject_id` → `SubjectNotFoundError`/404.
  n8n **workflow C** (`Schedule → /tools/compliance_run_reminders`) ships inactive; the manual `curl`
  trigger it documents is exactly the call exercised above. _(The `reminders.channel` CHECK is applied
  by `init.sql` on a fresh boot — as with Slice 2's `submissions.status` CHECK; here it was applied to
  the live DB to verify the DDL, matching what a clean rebuild would enforce.)_

> **Fresh-boot fix (shipped with Slice 1, ai-mcp-server-v1):** the clean rebuild surfaced a latent
> first-run bug — the MCP server's corpus-provenance self-check (`config_check.py`) queried
> `document_chunks` (a rag-client Alembic-owned table) and crashed boot with `UndefinedTableError`
> on a brand-new DB, because the rag-client's migrations run *after* the MCP server boots. The check
> now treats a not-yet-created corpus table as empty. This is a real bug for the "downloadable
> truly-local intro app" first-run path, masked until the DB was wiped. Covered by a regression test.

## Open Questions
- [ ] **Email intake mechanics** — how received-by-email documents reach B (a polled mailbox via n8n
      vs. a forwarding address parsed by a Core tool); ties to A10/SSRF review. _Still open — B's
      Slice 4 is reminder **egress** (SMTP send), not intake; the inbound-email path is unbuilt._
- [x] **Escalation recipients** — _(Slice 4, wedge answer.)_ Resolved for the wedge: **a single
      Instance mailbox** (`REMINDER_TO`) receives every reminder, with the Pack role (incl.
      `escalation_target`) recorded on the `reminders`/audit rows. The **real-account** form (role →
      resolved address) stays **deferred behind the `get_current_user()`/auth seam** — routing goes
      live with no engine change once auth lands.
- [x] **Reminder idempotency** — _(Slice 4.)_ Resolved at the app layer: the engine skips a cadence
      step whose Core `kind` already has a live `reminders` row for the subject (one send per
      `(subject, kind)`). A DB partial-unique index is the harder backstop (noted seam), not needed for
      the wedge's single-run cadence.
- [ ] **Status regression policy** — exact rules for when an `approved` item may move back (operator
      override only, with reason — confirm). _Unchanged by Slice 4 (reminders don't mutate status)._
- [ ] **Record-authority posture (Mode A vs B)** for the inspection-ready permanent file — who holds
      the authoritative packet (theirs vs us). Pairs with the boundary's open "default posture per
      vertical" question; decide before a real deployment (the demo runs Mode A with stand-ins).
- [ ] **Demo harness scope** — how faithfully the presentation trigger-form + mock SoR mimic a real
      inbound event / park target, so the demo→production swap to real `tools/` connectors stays a
      drop-in (no Core change).
