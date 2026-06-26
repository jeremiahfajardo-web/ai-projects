# Feature: Phase 4 — Workflow extensibility: Plugin SDK + n8n

## Status
[x] Spec  [x] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-26 — implemented. Plugin SDK + 12-tool migration + example/demo
plugins + dynamic admin Tool Tester shipped; MCP pytest suite green (61 tests). RAG
migration 0005, equipment-manual fixtures + ingest script, and the two n8n workflow exports
committed. **Remaining for "Testing":** live end-to-end run — `./start.ps1`, apply 0005,
run `demo/ingest_demo_docs.py`, import both n8n workflows and execute against the live API
(needs the Docker stack up; not run in this coding session)._

## Problem Statement
The stack is now a working, fully-local intro app — but extending it still means
**editing internals**. Adding an MCP tool today requires hand-wiring a block in
`ai-mcp-server-v1/main.py` (a Pydantic request model, an `@app.post("/tools/<name>")`
route, a `Depends(_ctx)` + `Depends(require(Tier.x))` guard, and a `run_tool()` call) —
~12 near-identical blocks already exist. A prospective client who wants to add a custom
capability (an internal search, a domain API, a bespoke retrieval step) has to crack open
the server's main file and replicate that boilerplate correctly.

Phase 4 turns extension into a **drop-in operation** and gives the no-code audience a
visual path. This is the "extensibility" seam from the rework plan's *defer-the-features,
build-the-seams* rule:
- **Plugin SDK** — the *code* path: drop a `tools/<name>.py` file → new MCP tool, no edits
  to `main.py`.
- **n8n** — the *visual/no-code* path: wire the existing RAG/MCP HTTP endpoints into
  workflows.

Hard guardrail (locked with the user): **no runtime code-exec.** Plugins are Python files
loaded at startup, never arbitrary code `eval`'d from a request.

## Acceptance Criteria
- [x] Dropping a new `tools/<name>.py` (declaring a tool spec + handler + tier) into
      `ai-mcp-server-v1/tools/` and restarting the server **auto-registers** a
      `POST /tools/<name>` endpoint — **no change to `main.py`**. _(via `sdk.discover()` +
      `register_tools()`.)_
- [x] Auto-registered tools keep the existing cross-cutting behaviour for free: per-call
      logging to `mcp_tool_calls`, the `mcp_tool_timeout_seconds` timeout, and auth-tier
      enforcement (401 missing key / 403 wrong tier) — i.e. each handler is still wrapped in
      `run_tool()` under the declared `Tier`.
- [x] The existing ~12 tools are migrated onto the same convention (one registration path,
      not two); the live HTTP contract for every current tool is unchanged. _(thin-wrapper
      handlers; `get_trusted_sources` moved GET → POST per decision #3.)_
- [x] A new plugin shows up in the **admin Tool Tester** (`static/admin.html`) and is
      callable from it, with request validation (Pydantic) and the OpenAPI schema populated.
      _(Tester now reads `GET /tools` dynamically.)_
- [x] `docs/extending.md` documents the contract + a worked example; one **example plugin**
      ships in `tools/echo.py` and is exercised by a test (`test_plugins.py`).
- [x] **n8n:** `ai-infrastructure-v1/n8n/README.md` describes the RAG + MCP HTTP endpoints as
      n8n HTTP-Request targets, and the **two starter workflows** are committed as JSON
      exports under `n8n/workflows/`. _(Clean-import verification is the live "Testing" step.)_
- [x] **Demo workflow A — "Ask your documents"** (flagship): n8n webhook → `POST /api/query`
      → cited answer. Vertical = **equipment/product manuals**; fixtures +
      `demo/ingest_demo_docs.py` ship in the RAG repo.
- [x] **Demo workflow B — live business-data Q&A via MCP**: webhook → HTTP node → MCP tool.
      Dummy dataset = RAG migration `0005` (`demo_invoices`/`demo_inventory`, SELECT to
      `mcp_user`); parameterized tools = `tools/demo_business.py`
      (`count_open_invoices`, `inventory_lookup`).
- [x] (Deferred — see Open Questions #5) The parallel **RAG pipeline-step hook** is NOT built
      this phase.

## Affected Repos / Surfaces
- **ai-mcp-server-v1** (primary): a new discovery/registration module (e.g. `plugins.py`);
  `main.py` loses the hand-wired tool blocks in favour of an auto-mount loop; `tools/*`
  modules gain a `TOOL_SPECS` declaration (request models move out of `main.py` into the
  tool module they belong to); `static/admin.html` Tool Tester reads the discovered set;
  `docs/extending.md` + an example plugin.
- **ai-infrastructure-v1**: n8n endpoint docs + the two starter workflow JSON exports; no
  compose change required (the `ai-n8n-v1` service already exists from Phase 2).
- **ai-rag-llm-client-v1 / ai-database-v1**: demo seed content — Workflow A's vertical
  document fixtures (+ ingest script) and Workflow B's dummy operational tables
  (`demo_invoices` / `demo_inventory`) via a migration or seed script, kept separate from the
  stack's own tables. (The deferred RAG pipeline-step hook would have lived here — not built.)

## Inputs
The SDK contract — what a plugin module declares:

| Name | Type | Source | Notes |
|---|---|---|---|
| `TOOL_SPECS` | `list[ToolSpec]` | module top-level | one entry per tool the file exposes |
| `ToolSpec.name` | str | declaration | becomes `/tools/<name>`; unique across all modules |
| `ToolSpec.description` | str | declaration | shown to the LLM + Tool Tester |
| `ToolSpec.request_model` | `type[BaseModel]` | declaration | Pydantic v2 model = the tool's params (keeps `Field` constraints + OpenAPI) |
| `ToolSpec.tier` | `Tier` | declaration | `read`/`write`/`delete` — enforced via `require()` |
| `ToolSpec.handler` | async callable | declaration | `async def (*, pool, ctx, params) -> result` |

## Outputs / Response Shape
Each tool's response is whatever its handler returns (unchanged from today — tools return
`list[dict]` / `dict`). The SDK adds **discovery introspection** for the admin UI / docs:
```json
{ "tools": [
  { "name": "document_search", "description": "...", "tier": "read",
    "parameters": { "...": "JSON schema derived from request_model" } }
] }
```

## Data Flow
```
startup (lifespan)
  → plugins.discover()            scan tools/*.py, import, collect TOOL_SPECS
  → for each ToolSpec:
       app.add_api_route(
         f"/tools/{spec.name}", _make_endpoint(spec), methods=["POST"])
       # _make_endpoint binds: req: spec.request_model, ctx=Depends(_ctx),
       #   _key=Depends(require(spec.tier)) → run_tool(spec.handler(...),
       #   tool_name=spec.name, input_params=req.model_dump(), **ctx, pool=pool)

request: POST /tools/<name>  (X-MCP-API-Key, X-User-ID, X-Session-ID)
  → auth tier check → Pydantic-validate body → run_tool(handler) [timeout+log]
  ← handler result (logged to mcp_tool_calls)
```

## Schema Impact
**None.** Phase 4 is registration/packaging + docs; it adds no tables or columns. Tool calls
continue to log to the existing `mcp_tool_calls` table. (If a future plugin needs its own
table, that plugin owns the migration — out of scope here.)

## Seams & Forward-Compatibility
- The SDK **is** a seam: it makes new capabilities additive (drop a file) instead of a
  `main.py` refactor — the same "build the seam" philosophy as the providers/ and
  `get_current_user()` seams from earlier phases.
- `_key_tier()` in `auth.py` is already a documented extension point ("Extend this dict or
  load from DB for multi-key setups") — per-plugin or per-client keys bolt on there later.
- The optional RAG pipeline-step hook mirrors the same drop-in convention so a client can
  insert a custom retrieval/post-process step without forking the pipeline.

## Edge Cases & Error Handling
- **Duplicate tool name** across modules: fail fast at startup (clear error naming both
  files) rather than silently shadowing.
- **Malformed plugin** (missing `TOOL_SPECS`, bad handler signature, import error): log and
  **skip that module**, keep the server booting; surface the skip in startup logs + the
  discovery endpoint. (A broken third-party plugin must not take the server down.)
- **Auth:** unchanged — missing key → 401, insufficient tier → 403, via `require(spec.tier)`.
- **Timeout / handler exception:** unchanged — `run_tool()` still maps these to 504/500 and
  logs `status` + `error_message`.
- **n8n:** starter workflows must use the in-cluster hostnames (`http://ai-mcp-server-v1:8001`,
  `http://ai-rag-llm-client-v1:8000`) and the `X-MCP-API-Key` header, not host ports.

## Out of Scope for This Feature
- Runtime/arbitrary code execution, a plugin marketplace, hot-reload without restart.
- Per-plugin DB migrations / plugin-owned schema.
- Auth beyond the existing tier model (per-client keys are a later additive change).
- Cloud LLM/embedding adapters (that's the providers/ seam, separate).

## Test Plan
- **Unit**: `discover()` collects specs from a fixture `tools/` dir; duplicate-name raises;
  malformed module is skipped (not fatal); `_make_endpoint` wires tier + run_tool correctly
  (mock pool + handler).
- **Integration** (`httpx.AsyncClient` + the MCP app): the shipped **example plugin** is
  reachable at `POST /tools/<example>`, enforces its tier (401/403 paths), validates its
  body, and logs a row to `mcp_tool_calls`; every pre-existing tool still answers with the
  same contract after migration.
- **Manual / verify**: drop a sample plugin into `tools/`, restart MCP, confirm it appears
  in the admin Tool Tester and is callable; import a starter workflow into `ai-n8n-v1` and
  run it against the live API.

## Resolved Decisions (2026-06-26)
1. **Request model:** ✅ explicit Pydantic `request_model` per `ToolSpec` (preserves `Field`
   constraints + OpenAPI; no schema-to-model generation magic).
2. **Handler signature:** ✅ standardise on `async def (*, pool, ctx: ToolContext, params)`
   for all tools; migrate the existing ~12 handlers (and move their request models out of
   `main.py` into the tool modules). `ToolContext` carries `session_id` / `user_id` (+ room
   to grow), replacing today's loose `**params, session_id, user_id`.
3. **GET tools:** ✅ POST-only for plugins; migrate the one GET tool
   (`get_trusted_sources`) to `POST /tools/get_trusted_sources`.
4. **n8n starter content:** ✅ the two workflows in "Demo content" below — (A) "Ask your
   documents" flagship, (B) live business-data Q&A via MCP.
5. **RAG pipeline-step hook:** ✅ **deferred** — not built this phase. It is itself a seam
   (purely additive later); the MCP Plugin SDK + n8n already deliver the extensibility story.
   Revisit for RAG-quality work: a post-retrieval **re-ranker** is the likely first user of
   this hook. (Separately on the backlog: **parent/child chunking** as a new retrieval method
   — an ingestion + retrieval change, *not* a pipeline step. Both ideas trace to hybrid-search
   issues the user hit in the sibling "RAG Comparison" project. See memory:
   `project_rag_retrieval_backlog`.)

## Demo content (n8n workflows + seed data)
**Workflow A — "Ask your documents" (flagship, build first).** Chat front end (n8n webhook,
or a Slack/Teams trigger) → `POST /api/query` (or `/api/query/stream`) on the RAG client →
grounded answer with citations back to the source doc. Re-skins per vertical (HR policy,
equipment manuals, ops guides). _Seed data:_ a small vertical document set ingested via
`/api/ingest` (committed as demo fixtures + an ingest script).

**Workflow B — live business-data Q&A via MCP.** NL question → n8n AI-agent/HTTP node → MCP
tool call into **current operational data** → formatted answer ("how many open invoices over
30 days?", "stock on SKU 4471?"). This is the purest Plugin-SDK showcase. _Requires:_
- A **dummy operational dataset** — e.g. `demo_invoices`, `demo_inventory` tables seeded with
  fixture rows. Owned by a migration (RAG client Alembic) or a demo seed script; kept clearly
  separate from the stack's own tables. **Decision needed at build time:** where the demo
  schema lives (see build-time notes).
- **Parameterized MCP plugin tools** that query it — e.g. `count_open_invoices(days_overdue)`,
  `inventory_lookup(sku)`. **No LLM-generated SQL** (safety + determinism); the tools expose
  typed parameters and run fixed queries. These ship as the worked Plugin-SDK examples.

> The contrast is the selling point: **RAG answers "what does our policy say," MCP answers
> "what's true right now"** — both in one demo shows real range.

_Build-time decisions to settle in the Phase 4 session:_ which vertical for Workflow A's docs;
where the demo business schema lives + how it's seeded; the exact parameter set for the two
business tools.
