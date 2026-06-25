# Feature: Phase 1 — Schema Foundations (1024 embeddings + provenance + user_id + soft-delete)

## Status
[x] Spec  [x] In Progress  [x] Testing  [x] Done

_Last updated: 2026-06-25 — implemented + verified end-to-end on a clean DB. Three
bugs surfaced during verification and were fixed: (1) migration head branch — renamed
to 0004 chaining after 0003_add_attached_filename; (2) ORM FK to users removed (DB-level
FK kept) to avoid NoReferencedTableError; (3) mcp_user SELECT on rag-owned tables codified
via ALTER DEFAULT PRIVILEGES in create_users.sh (was lost on clean rebuild)._

## Problem Statement
The intro app needs its data foundations to be both upgraded and forward-compatible
**now**, because all three changes are destructive-to-retrofit: a stronger 1024-dim
embedding model, provenance so a future model swap can't silently corrupt retrieval, and
`user_id` ownership + soft-delete so real auth/multi-user is an additive layer later. Doing
them together in one clean-DB pass avoids repeated re-ingestion.

## Acceptance Criteria
- [x] All vector columns are `VECTOR(1024)`; embeddings come from `mxbai-embed-large`. (verified: psql `vector(1024)`, ingest provenance `mxbai-embed-large / 1024`)
- [x] Query-side embeds use the mxbai prefix; chunk-side embeds do not. (verified: retrieval returns the ingested chunk)
- [x] Every vector row records `embedding_model` + `embedding_dimension` at write time. (verified on `document_chunks`)
- [~] A model/dimension mismatch fails fast: startup `RuntimeError` + per-request `409`. (startup success path verified — MCP healthy logs "alignment OK"; the mismatch/failure path is implemented but was not deliberately triggered)
- [x] A `users` table exists with one seeded default user (fixed well-known UUID). (verified)
- [x] Owned tables carry `user_id` + `deleted_at`; writes stamp it via `get_current_user()`. (verified: `document.user_id` = seed UUID; documents list filters by owner)
- [x] Global tables (`trusted_sources`, `web_cache`) stay unscoped; `error_log.user_id` nullable.
- [x] Clean `start` on a wiped `E:/Database` brings the stack up healthy; ingest + query work end-to-end with 1024-dim vectors. (verified)

## Affected Repos / Surfaces
- **ai-database-v1:** `init.sql` (dims, provenance, `users`, `user_id`/`deleted_at`, seed), `create_users.sh` (grants on `users`).
- **ai-rag-llm-client-v1:** Alembic `0003` (`document_chunks`→1024 + provenance; `documents`/`experiments` ownership), `services/rag.py` (mxbai prefix, provenance on insert, alignment), `services/ingestor.py`, `routes/query.py` + `mcp_client.py` (pass `user_id`), config defaults, new `get_current_user()` + alignment helper.
- **ai-mcp-server-v1:** `config.py` (model/dims), `tools/{memory,vector,web,rag}.py` (mxbai prefix on query embeds, provenance on insert, `user_id` scoping), startup alignment check.
- **ai-infrastructure-v1:** `docker-compose.yml` env defaults; `.env.example` files.

## Schema decisions (pin-down)
- **`users`**: `id UUID PK DEFAULT gen_random_uuid()`, `created_at`, `deleted_at`,
  `username TEXT UNIQUE` (partial-unique WHERE deleted_at IS NULL), nullable `password_hash`
  + auth columns **left empty/unused now** (auth-ready, no auth logic).
- **Default user**: seed a fixed UUID `00000000-0000-0000-0000-000000000001`, username
  `default`. `get_current_user()` returns this until real auth lands.
- **`user_id` type change**: existing owned tables use `user_id TEXT` (value `'default'`).
  Clean wipe lets us switch to `user_id UUID NOT NULL REFERENCES users(id)`. The MCP
  `X-User-ID` header now carries the default user's UUID string.
- **Owned tables** (add `user_id` + `deleted_at`): `memory_embeddings`, `sessions`,
  `turns` (via `session_id`→keep, also stamp `user_id` for direct filtering), `user_facts`,
  `mcp_tool_calls`, plus RAG-side `documents`, `experiments`.
- **Provenance columns** on `memory_embeddings`, `web_cache`, `document_chunks`:
  `embedding_model TEXT NOT NULL`, `embedding_dimension INTEGER NOT NULL`.
- **Vector dims**: `VECTOR(768)` → `VECTOR(1024)` everywhere; recreate every `ivfflat` index.

## Data Flow (alignment check)
```
startup (both services) → probe configured embed model dim → compare to VECTOR(N) column
  → mismatch → RuntimeError (app refuses to boot)
per request (ingest / query / memory_write) → if rows exist, compare configured
  model+dim to recorded embedding_model/embedding_dimension → mismatch → 409
```

## Seams & Forward-Compatibility
- **`get_current_user()`** is the single ownership seam — real JWT/MFA later flips this one
  function; no per-route or data change.
- **Embedding provider**: `_embed_text` helpers centralise the mxbai prefix + provenance so
  a future provider seam (Phase 3) wraps one place, not every call site.

## Edge Cases & Error Handling
- Empty corpus → alignment check is a no-op (first ingest defines the model).
- mxbai unavailable at startup → `RuntimeError` with actionable message (don't boot broken).
- `web_cache` is global/shared → no `user_id`; still records provenance.

## Out of Scope for This Feature
- Any login UI / JWT / auth logic (only the empty `users` columns + seam).
- Containerising Ollama / model pull (Phase 2). Phase 1 still uses host Ollama with the
  new model name; `mxbai-embed-large` must be pulled on the host to test.
- FastAPI rewrite (Phase 3).

## Test Plan
- **Unit:** mxbai prefix applied to query embeds only; provenance fields populated on insert;
  alignment check returns 409 on mismatch, no-op on empty corpus.
- **Integration:** clean DB → ingest a doc → `document_chunks.embedding` is 1024 + provenance
  set → semantic query returns hits scoped to the default user.
- **Manual smoke:** `ollama pull mxbai-embed-large` on host, wipe `E:/Database`, bring up,
  ingest + query, confirm 1024 dims in `psql`.

## Open Questions
- [ ] None blocking — clean wipe approved; default-user UUID fixed above.
