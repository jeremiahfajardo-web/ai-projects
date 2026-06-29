# Feature Spec Template — ai-projects

Every non-trivial feature begins with a spec saved to `docs/features/<feature-name>.md`
(in the repo the feature primarily lives in, or in `ai-projects/docs/features/` for
cross-repo work). Author the spec **before** writing implementation code. The spec is the
source of truth — if the implementation diverges, update the spec first and note why.

Each phase of the local-intro-app rework (`~/.claude/plans/optimized-mapping-harbor.md`)
gets a spec before its build starts.

Copy everything below the line into the new file and fill it out.

---

# Feature: <Title>

## Status
[ ] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: <YYYY-MM-DD> — <one-line note>_

## Problem Statement
<One to three sentences: the problem this solves, what prompted it, the intended
outcome. Why does it need to exist? What breaks or is missing without it?>

## Acceptance Criteria
- [ ] <Specific, testable behaviour from the user's perspective>
- [ ] <Each item independently verifiable>
- [ ] <Include error/edge-case behaviours, not just the happy path>

## Affected Repos / Surfaces
<Which of ai-infrastructure-v1 / ai-database-v1 / ai-mcp-server-v1 /
ai-rag-llm-client-v1 does this touch, and where (route, service, schema, compose)?>

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| <name> | <type> | <UI / API / config / env> | <validation, defaults> |

## Outputs / Response Shape
```json
{ "field": "type and description" }
```

## Data Flow
<Trace the request from entry point to persistence and back.
Format: ComponentA → function() → ExternalDep → response shape.>

Example:
```
Browser QueryInput → POST /api/query/stream → routes/query.py
  → providers/ollama (embed query, mxbai 1024)
  → services/rag.retrieve()       (pgvector + BM25, RRF)
  → MCP /tools/* via providers seam (tool-calling loop)
  → persist turn (single transaction, user_id stamped)
  ← SSE: step / tool_call / done events
```

## Schema Impact
<Tables/columns added or modified? Migration required? Destructive (re-ingest)?
If none, write "None.">
- Ownership: does every new table carry `user_id` + `deleted_at`?
- Provenance: do new vector columns record `embedding_model` + `embedding_dimension`?

## Seams & Forward-Compatibility
<What is deferred, and what seam keeps the later addition additive?
(provider adapter, get_current_user accessor, normalized child table, …)>

## Edge Cases & Error Handling
- <Condition>: <HTTP status, message, side effects>
- <Condition>: <…>

## Security Review
Reviewed against [docs/security-checklist.md](security-checklist.md) — the canonical
OWASP + LLM list with this stack's posture. Copy the checkbox skeleton from the bottom of
that file and, for **every** item, either tick it (one line on *how*), mark
`N/A — <why>`, or `deferred — <seam>`. No item may be left silently blank — this section
is part of the Definition of Done (see CLAUDE.md). Paste the filled skeleton here.

## Out of Scope for This Feature
- <Related things explicitly NOT in this ticket>

## Test Plan
- **Unit**: <what to mock (Ollama/DB), what to assert>
- **Integration**: <real DB/Ollama scenario + expected result; httpx.AsyncClient>
- **Frontend**: <Vitest assertions on component render / interactions>

## Smoke Test (user-performed, on the running stack)
A documented manual check so the live verification is traceable and repeatable — green
pytest is not "done" (see CLAUDE.md: a live smoke precedes commit). Fill in concrete steps.
- **Pre-reqs / config**: <env vars to set in `ai-infrastructure-v1/.env`, whether a
  `docker compose up -d --build` is needed (new deps / code), any data to ingest first>
- **Steps**: <numbered, copy-pasteable: the exact action(s) — e.g. run a query, hit an
  endpoint, click a UI control>
- **Expected / pass criteria**: <what proves it works — a log line to grep
  (`docker logs -f <svc>`), a UI element/badge, a response field, a status code>
- **Negative / fallback check**: <toggle the feature off or break a dependency; confirm
  graceful degradation, not a crash>
- **Result**: <user pastes outcome here: PASS/FAIL + notes/date — keep as the record>

## Open Questions
- [ ] <Unresolved decisions needing input before implementation starts>
