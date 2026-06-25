# CLAUDE.md — ai-projects (workspace umbrella)

## Overview

`ai-projects` is the umbrella for a **fully local, containerised AI stack**: document
ingestion, agentic RAG, LLM generation over MCP tools, and persistent memory — **no
cloud API keys required**. Everything runs on the user's machine via Docker Compose and
a local Ollama.

**Solo developer — you (Claude) are the co-pilot for every SDLC phase** (requirements,
architecture, implementation, testing, evaluation).

## Active Direction (2026-06-25)

The stack is being reworked into a **downloadable "truly local" intro app** a prospective
client can run with minimal setup — built so a full client deployment is an **additive**
next step, not a rewrite. Governing rule: **defer the features, build the seams.**

Authoritative plan: `~/.claude/plans/optimized-mapping-harbor.md`. Headline changes:
- Embeddings `mxbai-embed-large` → **`VECTOR(1024)`** (+ provenance/alignment check)
- RAG client **Flask → FastAPI** rewrite (the MCP server is already FastAPI/async)
- **Containerised Ollama** with **GPU auto-detect** (`llama3.1:8b` GPU / `llama3.2:3b` CPU)
- Dedicated **`ai-n8n-v1`** container; **Plugin SDK** (auto-discovered MCP tools) + n8n
- Schema-only **`user_id`** ownership + **soft-delete** behind a `get_current_user()` seam
- A **`providers/`** seam so a cloud LLM/embedding adapter is additive later

Phased: **0** foundations/docs · **1** schema (1024+provenance+user_id+soft-delete, clean
DB wipe) · **2** containerise Ollama + GPU + `ai-n8n-v1` + one-command start · **3**
FastAPI + Pydantic + provider seam + design-token CSS · **4** Plugin SDK + n8n workflows.

> Docs (this file, the READMEs, `docs/architecture.md`) still describe parts of the
> **pre-rework** running stack. They are updated **per phase as code actually ships** —
> trust the plan for the target, the code for current state.

## Repositories

| Repo | Role | Port |
|---|---|---|
| `ai-infrastructure-v1` | Docker Compose orchestration + shared `.env` | — |
| `ai-database-v1` | PostgreSQL 16 + pgvector schema, least-privilege users | 5432 |
| `ai-mcp-server-v1` | FastAPI MCP tool server (memory, web, vector, rag) — **reference impl** for async/pydantic patterns | 8001 |
| `ai-rag-llm-client-v1` | Vue 3 + (Flask→FastAPI) agentic RAG client | 8000 |
| `ai-n8n-v1` *(planned, Phase 2)* | Dedicated n8n for client workflows | 5678 |

Each repo is its **own git repo**; work for this effort is on branch
`feat/local-intro-app` (off `agentic_ai_attempt_v1`).

## Tech Stack (target state)

| Layer | Technology |
|---|---|
| Frontend | Vue 3 (Composition API) + Vite; design tokens; responsive (no PWA) |
| Backend | Python 3.12 / **FastAPI** (ASGI, uvicorn) — both services |
| Database | PostgreSQL 16 + pgvector (`VECTOR(1024)`, ivfflat) |
| RAG retrieval | pgvector cosine + PostgreSQL BM25, merged via RRF (k=60); semantic/keyword/hybrid |
| Embeddings | Ollama `mxbai-embed-large` (1024-dim), via a `providers/` seam |
| LLM | Ollama, containerised; `llama3.1:8b` (GPU) / `llama3.2:3b` (CPU) |
| Workflows | Dedicated `ai-n8n-v1` + Plugin SDK (auto-discovered MCP tools) |
| Auth | None yet — schema-only `user_id` behind `get_current_user()` seam |
| Containerisation | Docker Desktop + Docker Compose |

## Coding Standards

Full standards (docstring templates, FastAPI/Vue/SQL conventions, the resolve-by-id and
soft-delete rules) live in **[docs/coding-style.md](docs/coding-style.md)** — pull it when
authoring new modules. Summary:

- Python 3.11+ with type hints; `black` (88) + `ruff`; `pytest`.
- FastAPI app-factory + `lifespan` startup checks; Pydantic v2 schemas (`response_model=`).
- Async by default; `Depends()` injection; raw SQL only for pgvector similarity.
- Ollama I/O through the `providers/` seam — never scattered inline `httpx`.
- Vue 3 `<script setup>` + Pinia + Axios `services/api.js`; scoped styles; **no hard-coded
  hex** (tokens in `assets/theme.css`); shared logic in `composables/`.
- Alembic-only schema changes; `VECTOR(1024)` + ivfflat; embedding provenance.
- Every user-owned table: `user_id` + `deleted_at`. **Resolve rows by id, never by a
  display string.**

## SDLC Phase Instructions

- **Requirements:** before coding a feature, write a spec from
  [docs/feature-spec-template.md](docs/feature-spec-template.md) to `docs/features/<name>.md`.
  Spec is the source of truth; update it first if the build diverges.
- **Architecture:** for any new service/route, sketch the data flow first (caller →
  function → external dep → response shape). Flag schema-affecting decisions early —
  schema changes are expensive once data exists.
- **Feature dev:** branch `feat/<short-description>`; backend route + service + model
  first, then the Vue component; happy path then explicit error handling; write ≥2 unit
  tests right after a service.
- **Testing:** unit in `tests/unit/` (mock Ollama + DB); integration in `tests/integration/`
  (`httpx.AsyncClient` + uvicorn fixture, test DB); Vitest for composables/stores; target
  ≥80% coverage on `services/`. Run the suite before calling anything done.

## Gotchas & Known Constraints

- **Ollama:** today on the **Windows host** (`host.docker.internal:11434`); Phase 2 moves
  it into the `ollama` container and repoints `OLLAMA_BASE_URL=http://ollama:11434`.
- **GPU matters more than the container.** CPU-only `:8b` is 30–90s/response — the GPU
  auto-detect picks `llama3.2:3b` on CPU for a usable first run.
- **DB is a bind-mount** (`E:/Database`); `docker-compose down -v` does **not** clear it —
  wipe `E:/Database/*` manually for a clean restart. Current data is disposable.
- **Embedding-model change is destructive** — drop the vector column + ivfflat index and
  re-ingest; the alignment check fails fast on a model/dim mismatch.
- **Resolve by id, never display string** — a `filename`/`name` is unique only per-user;
  resolving by it breaks silently once two users collide.
- **`ai-n8n-v1` ≠ the user's existing standalone `n8n`** (`E:/n8n`, :5678) — keep them
  isolated (separate volume, encryption key, host port).

## Per-repo docs

Each repo has its own `CLAUDE.md` (role, key files, repo-specific gotchas) that points
back here and to `docs/coding-style.md` for the shared standards.
