# Feature: Phase 2 — Containerize Ollama + GPU auto-detect + single-command setup

## Status
[x] Spec  [x] In Progress  [x] Testing  [x] Done

_Last updated: 2026-06-25 — spec authored ahead of implementation._

## Problem Statement
Today Ollama runs on the **Windows host** (`host.docker.internal:11434`) and the LLM
+ embedding models must be pulled by hand before anything works. That is a host
dependency a prospective client cannot be expected to satisfy. The intro app must be
**downloadable and runnable with one command, no host Ollama**: a containerized Ollama
that auto-pulls its models on first boot, picks the right model for the available
hardware (GPU vs CPU), and brings up a bundled, isolated n8n alongside db + mcp + rag.

## Acceptance Criteria
- [ ] A fresh `./start.ps1` (or `./start.sh`) on a host with **no Ollama installed**
      brings the whole stack up; no manual `ollama pull` step.
- [ ] The `ollama` service auto-pulls the embedding model + the selected LLM model on
      first boot (one-shot `ollama-init`); subsequent boots reuse the named volume.
- [ ] Every service reaches Ollama at `http://ollama:11434` — no `host.docker.internal`
      remains in compose or either `config.py`.
- [ ] GPU host → `llama3.1:8b` with the GPU override applied; CPU host → `llama3.2:3b`,
      base compose only. Selection is automatic (probes `nvidia-smi`).
- [ ] mcp + rag only start their alignment check **after** models are present
      (`ollama-init` completed) — no boot failure from a missing model.
- [ ] The RAG client tolerates a slow-to-ready Ollama (bounded retry, not a hard
      one-shot raise) and the error text no longer says "Ollama Windows application".
- [ ] A dedicated `ai-n8n-v1` comes up on `${N8N_HOST_PORT:-5678}` with its **own**
      named volume + encryption key — the user's existing standalone `n8n` (`E:/n8n`,
      :5678) is untouched.
- [ ] All healthchecks green; an end-to-end query returns.

## Affected Repos / Surfaces
- **ai-infrastructure-v1:** `docker-compose.yml` (new `ollama`, `ollama-init`,
  `ai-n8n-v1` services; named volumes; repointed `OLLAMA_BASE_URL`; `depends_on`;
  drop obsolete `version:` key), new `docker-compose.gpu.yml`, new `start.ps1` /
  `start.sh`, `.env.example`, `README.md`, `CLAUDE.md`.
- **ai-mcp-server-v1:** `config.py` `ollama_base_url` default → `http://ollama:11434`.
- **ai-rag-llm-client-v1:** `app/config.py` `OLLAMA_BASE_URL` default →
  `http://ollama:11434`; `app/__init__.py` `_verify_ollama` → bounded retry.
- **ai-projects:** `docs/architecture.md` (record the containerization decision).

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| GPU presence | bool | `nvidia-smi` probe in launcher | Selects model + compose override |
| `OLLAMA_LLM_MODEL` | str | launcher-exported env (overrides `.env`) | `llama3.1:8b` GPU / `llama3.2:3b` CPU |
| `OLLAMA_EMBED_MODEL` | str | `.env` | `mxbai-embed-large` (1024-dim, Phase 1) |
| `N8N_HOST_PORT` | int | `.env` | Default `5678`; set `5679` to run beside existing n8n |
| `N8N_ENCRYPTION_KEY` | str | `.env` | Distinct from the existing standalone instance |

## Data Flow
```
./start.ps1 → probe nvidia-smi
  GPU → export OLLAMA_LLM_MODEL=llama3.1:8b; compose -f base -f gpu up -d
  CPU → export OLLAMA_LLM_MODEL=llama3.2:3b; compose -f base up -d
        │
        ├── ollama (serve)  ── healthcheck: `ollama list` ──► healthy
        ├── ollama-init     ── pulls embed + LLM models ──► exits 0
        ├── ai-database-v1  ── pg_isready ──► healthy
        ├── ai-mcp-server-v1   depends_on: db healthy + ollama-init completed
        ├── ai-rag-llm-client-v1 depends_on: db healthy + mcp healthy + ollama-init completed
        └── ai-n8n-v1       (own volume + encryption key, :${N8N_HOST_PORT})

runtime: mcp/rag → http://ollama:11434/api/{embeddings,chat,generate}
```

## Schema Impact
None. Phase 2 is orchestration only — no migrations, no table/column changes.

## Seams & Forward-Compatibility
- **`OLLAMA_BASE_URL` indirection** is the seam: moving inference host→container is a
  single URL flip because every call already reads the configured base URL.
- **GPU override is additive** — `docker-compose.gpu.yml` layers nvidia device
  reservations on the base file; CPU hosts never load it. A future ROCm/other-accel
  override is another sibling file, no base change.
- **`ai-n8n-v1` isolation** (own volume, port, encryption key) keeps the bundled n8n
  from ever commingling with the user's existing instance, and lets a client
  deployment swap the volume/key without touching the app.

## Edge Cases & Error Handling
- **Ollama slow to accept connections after healthcheck:** RAG `_verify_ollama` retries
  with bounded backoff before raising, instead of a single hard failure.
- **Model pull fails (network):** `ollama-init` exits non-zero → dependents do not start;
  the failure is visible in `docker compose logs ollama-init`.
- **Port 5678 already taken by the existing n8n:** user sets `N8N_HOST_PORT=5679`; both
  run side by side (distinct volumes + keys).
- **Port 11434 taken by a host Ollama:** `OLLAMA_HOST_PORT` remaps the host binding; the
  container network address (`ollama:11434`) is unaffected.
- **No NVIDIA GPU / no `nvidia-smi`:** launcher falls back to CPU + `llama3.2:3b`.

## Out of Scope for This Feature
- FastAPI rewrite of the RAG client + provider seam (Phase 3).
- Plugin SDK + n8n starter workflows (Phase 4) — this phase only stands the n8n
  **container** up; no workflows are shipped yet.
- Non-NVIDIA GPU acceleration (AMD/ROCm, Apple Metal).

## Test Plan
- **Manual smoke (primary):** on a clean machine with no host Ollama, run `./start.ps1`;
  confirm models auto-pull, all healthchecks green, a query returns. GPU box → `:8b`;
  CPU box → `:3b`.
- **Isolation:** with the existing standalone `n8n` running on :5678, set
  `N8N_HOST_PORT=5679`, start the stack, confirm both n8n instances are reachable and
  the existing one's workflows are intact.
- **Race:** kill + restart `ollama` mid-boot; confirm the RAG client retries and
  eventually comes up rather than crash-looping.

## Open Questions
- [ ] None blocking.
