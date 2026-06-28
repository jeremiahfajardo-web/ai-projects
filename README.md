# ai-projects

A fully local, containerised AI stack: document ingestion, agentic RAG, LLM
generation over MCP tools, and persistent memory — no cloud API keys required.

Everything runs on your machine via Docker Compose, including a **containerised
Ollama** (GPU auto-detected). One command brings the whole stack up.

---

## Repositories

| Repo | Role | Port |
|---|---|---|
| [ai-infrastructure-v1](../ai-infrastructure-v1) | Docker Compose orchestration, GPU-aware launcher, shared `.env` | — |
| [ai-database-v1](../ai-database-v1) | PostgreSQL 16 + pgvector schema, least-privilege users | 5432 |
| [ai-mcp-server-v1](../ai-mcp-server-v1) | FastAPI MCP tool server (memory, web, vector, rag, demo) | 8001 |
| [ai-rag-llm-client-v1](../ai-rag-llm-client-v1) | FastAPI + Vue 3 agentic RAG client | 8000 |
| [ai-n8n-v1](../ai-infrastructure-v1) (bundled) | Isolated n8n for client workflows | 5678 |

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────────┐
│                      Docker bridge: ai-project                         │
│                                                                        │
│  ┌───────────────┐   ┌──────────────────────┐   ┌──────────────────┐  │
│  │    ollama     │   │  ai-rag-llm-client    │   │  ai-mcp-server   │  │
│  │  :11434       │◀──│     FastAPI :8000     │──▶│   FastAPI :8001  │  │
│  │ llama3.1:8b / │   │      Vue 3 SPA        │   │  15 tools / HTTP │  │
│  │ llama3.2:3b   │◀──────────────────────────── │  (auto-discovered)│  │
│  │ mxbai-embed   │   └──────────┬───────────┘   └────────┬─────────┘  │
│  └───────────────┘              │                         │            │
│  (models pulled once            └────────────┬────────────┘            │
│   by ollama-init)                            ▼                         │
│                                ┌────────────────────────┐              │
│                                │     ai-database-v1      │             │
│                                │  PostgreSQL 16 + pgvector│             │
│                                │  VECTOR(1024) / ivfflat  │             │
│                                │  host bind-mount (vol)   │             │
│                                └────────────────────────┘              │
│                                                                        │
│  ┌──────────────┐                                                      │
│  │  ai-n8n-v1   │  :5678 (isolated volume + encryption key)            │
│  └──────────────┘                                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Inter-container DNS uses the container name (`ollama:11434`, `ai-database-v1:5432`,
`ai-mcp-server-v1:8001`). No host Ollama install is required.

### Data flows

**Query flow (agentic RAG)**
```
Browser → POST /api/query/stream
  → [RAG] retrieve         hybrid pgvector + BM25 (via MCP document_search; local fallback)
  → [LLM] generate         Ollama (or optional cloud) with the enabled MCP tools, up to 5 turns
                           ↳ the model may call web_search, document_search, memory_read, … 
                           ↳ tool calls stream to the UI as tool_call events
  → [MCP] memory_write     store the conversation turn as episodic memory
  → Browser receives tokens (and tool-call rows) as they arrive via SSE
```
Tools advertised to the LLM are selected per request in the UI (or default to
`LLM_ENABLED_TOOLS`); memory recall and web access are LLM-callable tools, not fixed steps.

**Document ingestion**
```
Browser → POST /api/ingest (multipart)
  → text extraction (PDF / DOCX / XLSX / PPTX / MD / HTML / TXT)
  → structure-aware parent/child chunking (token-based)
  → Ollama embed (mxbai-embed-large, 1024 dims — passage side)
  → INSERT parents + embedded children (VECTOR(1024) + tsvector)
```

**MCP web crawl**
```
POST /tools/web_crawl_and_store
  → Brave Search API (n results)
  → Jina Reader (clean markdown)
  → chunk → embed → UPSERT web_cache
```

---

## Technology stack

| Layer | Technology | Notes |
|---|---|---|
| LLM inference | Ollama (containerised) | `llama3.1:8b` (GPU) / `llama3.2:3b` (CPU), auto-selected |
| Optional cloud LLM | Anthropic (Claude) | Demo-only, opt-in via `LLM_PROVIDER=anthropic`; **embeddings stay local** |
| Embeddings | Ollama (mxbai-embed-large) | 1024-dim vectors, via a `providers/` seam |
| Vector DB | PostgreSQL 16 + pgvector | `VECTOR(1024)`, ivfflat indexes (lists=100) |
| Full-text search | PostgreSQL tsvector + GIN | Hybrid with RRF merge (k=60) |
| RAG client backend | Python 3.12 / FastAPI | uvicorn (ASGI), asyncpg, Pydantic v2, httpx |
| RAG client frontend | Vue 3 + Vite | Built SPA, responsive, design tokens, SSE streaming |
| MCP tool server | Python 3.12 / FastAPI | asyncpg, 15 auto-discovered tools, tiered auth |
| Workflows | n8n (isolated) | Bundled `ai-n8n-v1` for client automations |
| Orchestration | Docker Compose | Bridge network, health checks, GPU-aware launcher |
| Web search / scraping | Brave Search / Jina Reader | Optional, for MCP web tools |

---

## Quick start

The authoritative, one-command setup lives in
[ai-infrastructure-v1](../ai-infrastructure-v1/README.md). Summary:

### 1. Prerequisites

- **Docker Desktop** (Linux containers). No host Ollama needed — it runs in a container.
- _(Optional)_ **NVIDIA GPU + Container Toolkit** — auto-detected to enable `llama3.1:8b`
  with GPU acceleration; CPU-only hosts fall back to `llama3.2:3b`.
- All sibling repos cloned under one parent (e.g. `C:\projects\`).

### 2. Configure environment

```bash
cd ai-infrastructure-v1
cp .env.example .env
# fill in every `changeme` value (DB passwords, MCP_API_KEY, N8N_ENCRYPTION_KEY,
# and the Brave/Jina keys for web tools)
```

### 3. Start the stack

```powershell
./start.ps1     # Windows (PowerShell) — probes nvidia-smi, picks the LLM model, builds + starts
```
```bash
./start.sh      # Linux / macOS
```

On first boot, `ollama-init` pulls the embedding + LLM models into a named volume
(several minutes — `docker compose logs -f ollama-init`), then the database, MCP
server, and RAG client come up in dependency order.

### 4. Open the UI

| Service | URL |
|---|---|
| RAG client (main UI) | [http://localhost:8000](http://localhost:8000) |
| MCP admin dashboard  | [http://localhost:8001/admin](http://localhost:8001/admin) |
| MCP API docs         | [http://localhost:8001/docs](http://localhost:8001/docs) |
| n8n                  | [http://localhost:5678](http://localhost:5678) (or `N8N_HOST_PORT`) |

---

## Clean restart (wipe data)

The PostgreSQL data lives in a host **bind-mount** at the path set by `DB_DATA_PATH`
in `ai-infrastructure-v1/.env` (e.g. `E:/Database`). Docker's `down -v` does **not**
clear bind-mounts — delete the directory contents manually.

```bash
cd ai-infrastructure-v1
docker compose down

# Wipe the database dir (Git Bash — adjust path to match DB_DATA_PATH)
rm -rf /e/Database/*

# Re-start (the init scripts re-run on the empty data dir)
./start.ps1
```

> Changing the embedding model is **destructive** — the `VECTOR(1024)` column + ivfflat
> index are model/dim-specific, and the MCP server's startup alignment check fails fast on a
> mismatch. Wipe and re-ingest after any embedding-model change.

---

## Environment variables reference

All variables live in `ai-infrastructure-v1/.env`; see
[.env.example](../ai-infrastructure-v1/.env.example) for the authoritative list and defaults.

### Database
| Variable | Description |
|---|---|
| `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` | Superuser + database name (default db `ai-db`) |
| `RAG_DB_PASSWORD` / `MCP_DB_PASSWORD` | Least-privilege app account passwords |
| `POSTGRES_HOST_PORT` | Host-side port (default `5432`) |
| `DB_DATA_PATH` | Host bind-mount for the data directory |

### Ollama (containerised; shared by both services)
| Variable | Description |
|---|---|
| `OLLAMA_BASE_URL` | Ollama URL (default `http://ollama:11434`) |
| `OLLAMA_LLM_MODEL` | Generation model (launcher-selected: `llama3.1:8b` GPU / `llama3.2:3b` CPU) |
| `OLLAMA_EMBED_MODEL` | Embedding model (default `mxbai-embed-large`) |
| `EMBEDDING_DIMENSIONS` | Vector width — must match the model (default `1024`) |
| `LLM_TEMPERATURE` / `LLM_MAX_TOKENS` / `LLM_TIMEOUT` / `EMBED_TIMEOUT` | Generation + I/O tuning |

### LLM provider (optional cloud demo)
| Variable | Description |
|---|---|
| `LLM_PROVIDER` | `ollama` (default, local) or `anthropic` (cloud, demo-only) |
| `ANTHROPIC_API_KEY` / `ANTHROPIC_MODEL` | Used only when `LLM_PROVIDER=anthropic`; embeddings always stay on Ollama |

### MCP server
| Variable | Description |
|---|---|
| `MCP_API_KEY` | Auth key for all tool calls (tiered: read/write/delete) |
| `BRAVE_SEARCH_API_KEY` / `JINA_API_KEY` | Web search / scraping (optional) |
| `MCP_TOOL_TIMEOUT_SECONDS` | Per-tool timeout (default `120`) |
| `WEB_CACHE_DEFAULT_TTL_HOURS` / `MEMORY_DEFAULT_TTL_DAYS` | Cache / memory TTLs |
| `MCP_HOST_PORT` | Host port (default `8001`) |

### RAG client
| Variable | Description |
|---|---|
| `RAG_TOP_K` | Default retrieved chunks per query (default `5`) |
| `RAG_SIMILARITY_THRESHOLD` / `RAG_RELATIVE_THRESHOLD` | Absolute / relative similarity floors (default `0.20`) |
| `LLM_ENABLED_TOOLS` | CSV of MCP tools advertised to the LLM by default (UI selector overrides per request) |
| `RAG_HOST_PORT` | Host port (default `8000`) |

### n8n / shared
| Variable | Description |
|---|---|
| `N8N_HOST_PORT` / `N8N_ENCRYPTION_KEY` / `N8N_HOST` | Isolated n8n config (port, encryption key, host) |
| `DEFAULT_USER_ID` | Default memory/ownership user (a UUID; the seeded local user) |
| `LOG_LEVEL` | Logging level |

---

## Detailed documentation

- [Architecture deep-dive](docs/architecture.md)
- [ai-infrastructure-v1 README](../ai-infrastructure-v1/README.md)
- [ai-database-v1 README](../ai-database-v1/README.md)
- [ai-mcp-server-v1 README](../ai-mcp-server-v1/README.md) · [API reference](../ai-mcp-server-v1/docs/api-reference.md)
- [ai-rag-llm-client-v1 README](../ai-rag-llm-client-v1/README.md)
