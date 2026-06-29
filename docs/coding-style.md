# Coding Style — ai-projects

This is the **workspace-wide** style and commenting standard for every repo in the
`ai-projects` stack (`ai-infrastructure-v1`, `ai-database-v1`, `ai-mcp-server-v1`,
`ai-rag-llm-client-v1`). Each repo's `CLAUDE.md` links here for the full examples and
keeps only a brief summary inline so the always-loaded context stays lean.

These standards describe the conventions all new and refactored code follows under the
local-intro-app direction (see [architecture.md](architecture.md) → *Rework (shipped)* and
the plan at `~/.claude/plans/optimized-mapping-harbor.md`). The rework has shipped (both
services are FastAPI now); where any older code still predates a convention, match the
convention when you touch the file.

---

## Commenting Philosophy

Every key section of the codebase must include descriptive comments. The goal is that a
developer (or Claude in a future session) can understand *why* code exists, not just
*what* it does.

### Python — module-level docstring (top of every file)

```python
"""
tools/memory.py

MCP memory tools — semantic read/write over memory_embeddings.
Responsible for:
  1. Embedding content via the configured provider (mxbai-embed-large, 1024-dim)
  2. Cosine-similarity recall scoped to the calling user_id
  3. Writing episodic/semantic memories with provenance + TTL

Stateless — the asyncpg pool and settings are injected by the caller so the
module is trivially mockable in unit tests.
"""
```

### Python — function docstring (all public functions)

```python
async def memory_read(query: str, user_id: str, top_k: int = 5) -> list[dict]:
    """
    Embed the query and recall the top-k most similar memories for one user.

    Args:
        query:   Raw query string (not pre-processed).
        user_id: Owner scope — recall never crosses users.
        top_k:   Max memories to return. Higher = richer context, more tokens.

    Returns:
        List of dicts: {id, content, score, memory_type}. Ordered by score desc.

    Raises:
        ProviderUnavailableError: If the embedding model cannot be reached.
        ValueError: If top_k < 1.
    """
```

### Python — inline comments (non-obvious logic only)

```python
# mxbai-embed-large is asymmetric: the QUERY side needs this prefix, the stored
# chunk side does not. Skipping it measurably hurts recall.
prompt = f"Represent this sentence for searching relevant passages: {query}"
```

### Vue — component header comment (top of `<script setup>`)

```javascript
/**
 * ResponsePanel.vue
 *
 * Renders one streamed pipeline response. Receives a resolved response object
 * and displays: response text, latency badge, tool-call trace, system prompt.
 *
 * Props:
 *   - response (Object): { text, latencyMs, toolCalls, systemPrompt }
 *   - experimentId (String): UUID — used when submitting a human rating
 */
```

### Vue — inline comments (computed logic / watchers)

```javascript
// Re-fetch history after each submitted query so the log stays in sync
// without a manual refresh.
watch(() => store.lastExperimentId, fetchHistory)
```

### When NOT to comment

Skip comments on self-explanatory one-liners, standard boilerplate, and trivial
getters/setters. Comments add information; they never restate the code in English.

---

## Python / FastAPI Conventions

- Python 3.13+ (3.13 in containers, both services); **type hints required** on all signatures.
- Formatter: `black` (line length 88). Linter: `ruff`. Tests: `pytest`.
- **App-factory + `lifespan`** pattern: `create_app()` builds the app; an async
  `lifespan` context manager runs startup verifications (DB pool, provider/Ollama
  reachability, embedding alignment) and shutdown hooks. Reference impl:
  `ai-mcp-server-v1/main.py`.
- **Pydantic v2** for every request/response shape — schemas in `app/schemas/`, one
  file per resource. Routes declare `response_model=...`.
- Endpoints are `async def` by default; inject dependencies via `Depends(...)`.
- DB access through an async pool / async SQLAlchemy. **Raw SQL only for pgvector
  similarity** (`<=>`, `SET LOCAL ivfflat.probes`); everything else uses the ORM/query
  builder.
- **Provider seam:** all Ollama LLM/embedding I/O goes through the `providers/`
  interface (one `OllamaProvider` impl today) — never inline `httpx` calls to Ollama
  scattered across services. Adding a cloud provider later must be a new adapter, not a
  call-site edit.
- Services layer is **stateless** — config/pool injected by the caller, so every service
  is mockable.

## Vue 3 / Frontend Conventions

- Composition API with `<script setup>` throughout — never mix in the Options API.
- State: **Pinia**. HTTP: **Axios** via a single `services/api.js` wrapper.
- Component files PascalCase; kebab-case in templates.
- **CSS: scoped styles per component. No hard-coded hex/spacing** — every color, space,
  and radius comes from design tokens in `src/assets/theme.css` (CSS custom properties).
- **Responsive, not PWA** — flex/grid + media queries for mobile-friendly layouts. No
  service workers, manifests, or install prompts anywhere in the workspace.
- Shared display logic lives in `src/composables/` (`useFormatters`, `useSort`, …) — do
  not duplicate it inline across views.
- Linter: ESLint + Prettier.

## SQL / pgvector / Schema

- **All schema changes via Alembic migrations** (or the DB repo's init SQL for first-run
  schema) — never alter tables manually.
- Vector columns are `VECTOR(1024)` to match `mxbai-embed-large`. Always add an `ivfflat`
  index after initial data load. Changing the embedding model is a **destructive**
  migration (drop column + index, re-ingest) — plan for it.
- **Embedding provenance:** vector rows record `embedding_model` + `embedding_dimension`;
  a startup/per-request alignment check rejects a model/dimension mismatch (`409`) rather
  than silently returning garbage.
- **Ownership:** every user-owned table carries `user_id UUID NOT NULL REFERENCES
  users(id)`; reads filter by it, writes stamp it — always sourced from the single
  `get_current_user()` seam (returns the default local user until real auth lands).
- **Soft delete:** user-owned rows use `deleted_at TIMESTAMPTZ` (NULL = active). Hard
  deletes are operator-only.
- **Resolve entities by surrogate id, never a display string.** Load/navigate/`.find()`
  a row by its `id` — never by `filename`, `name`, `email`, or any display value. Display
  strings are unique only *within a user scope*; resolving by them silently breaks the
  moment two users share one. Selection events carry the `id`.

---

## General Principles

- All new code passes lint before it's "done".
- No secrets/keys/credentials in source — `.env` only.
- Every public function/method has a docstring.
- Prefer explicit over implicit; no magic values — use named constants or config.
- **Defer features, build seams.** When deferring scope, leave a clean extension point
  (a provider adapter, an auth accessor, a normalized child table) so the later addition
  is additive, not a teardown.

See [coding-style examples in context] by reading the reference implementation in
`ai-mcp-server-v1/` (already FastAPI/async/pydantic) when authoring new backend modules.
