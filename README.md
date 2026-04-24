# ai-projects

A fully local, containerised AI stack: document ingestion, agentic RAG, LLM
generation, and persistent memory — no cloud API keys required.

Everything runs on your machine via Docker Compose and Ollama.

---

## Repositories

| Repo | Role | Port |
|---|---|---|
| [ai-infrastructure-v1](../ai-infrastructure-v1) | Docker Compose orchestration and shared `.env` | — |
| [ai-database-v1](../ai-database-v1) | PostgreSQL 16 + pgvector schema, user creation | 5432 |
| [ai-mcp-server-v1](../ai-mcp-server-v1) | FastAPI MCP tool server (memory, web, vector) | 8001 |
| [ai-rag-llm-client-v1](../ai-rag-llm-client-v1) | Flask + Vue 3 agentic RAG client | 8000 |

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Windows Host Machine                     │
│                                                              │
│  ┌───────────────┐                                           │
│  │     Ollama    │  :11434                                   │
│  │  llama3:8b    │  LLM generation + embeddings              │
│  │ nomic-embed   │                                           │
│  └───────┬───────┘                                           │
│          │ host.docker.internal:11434                        │
│          │                                                   │
│  ┌───────┴────────────────────────────────────────────────┐  │
│  │               Docker bridge: ai-project                │  │
│  │                                                        │  │
│  │  ┌──────────────────────┐   ┌───────────────────────┐  │  │
│  │  │  ai-rag-llm-client   │   │   ai-mcp-server-v1    │  │  │
│  │  │      Flask :8000     │──▶│     FastAPI :8001     │  │  │
│  │  │      Vue 3 PWA       │   │   11 tools over HTTP  │  │  │
│  │  └──────────┬───────────┘   └───────────┬───────────┘  │  │
│  │             │                            │              │  │
│  │             └───────────┬────────────────┘              │  │
│  │                         ▼                               │  │
│  │              ┌────────────────────┐                     │  │
│  │              │  ai-database-v1    │                     │  │
│  │              │  PostgreSQL 16     │                     │  │
│  │              │  + pgvector        │                     │  │
│  │              │  D:/Database (vol) │                     │  │
│  │              └────────────────────┘                     │  │
│  └────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
```

### Data flows

**Query flow (agentic RAG)**
```
Browser → POST /api/query/stream
  → [MCP] memory_read      read relevant past memories
  → [RAG] retrieve         pgvector + BM25 hybrid search
  → [LLM] generate         Ollama streams tokens via SSE
  → [MCP] memory_write     store conversation turn
  → Browser receives tokens as they arrive
```

**Document ingestion**
```
Browser → POST /api/ingest (multipart)
  → text extraction (PDF / DOCX / XLSX / PPTX / MD / HTML / TXT)
  → chunking (512 tokens, 50 overlap)
  → Ollama embed (nomic-embed-text, 768 dims)
  → INSERT document_chunks (VECTOR(768) + tsvector)
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
| LLM inference | Ollama (llama3:8b) | Runs on Windows host, GPU or CPU |
| Embeddings | Ollama (nomic-embed-text) | 768-dim vectors |
| Vector DB | PostgreSQL 16 + pgvector | ivfflat indexes, lists=100 |
| Full-text search | PostgreSQL tsvector + GIN | Hybrid with RRF merge |
| RAG client backend | Python 3.12 / Flask | flask[async], SQLAlchemy, httpx |
| RAG client frontend | Vue 3 + Pinia + Vite | PWA, dark mode, SSE streaming |
| MCP tool server | Python 3.12 / FastAPI | asyncpg, 11 tools, 4-layer auth |
| Orchestration | Docker Compose | Bridge network, health checks |
| Web search | Brave Search API | Optional for MCP web tools |
| Web scraping | Jina Reader API | Optional for MCP web tools |

---

## Quick start

### 1. Prerequisites

- **Docker Desktop** — install and start it
- **Ollama** — [download for Windows](https://ollama.com/download/windows), install, start

Pull the required models (one-time):
```bash
ollama pull llama3:8b
ollama pull nomic-embed-text
```

Optional — store models on a larger drive:
```powershell
# PowerShell — set once, then restart Ollama from the system tray
[System.Environment]::SetEnvironmentVariable("OLLAMA_MODELS", "D:\OllamaModels", "User")
```

### 2. Configure environment

```bash
cd ai-infrastructure-v1
cp .env.example .env
```

Edit `.env` and fill in the required values:

```ini
# Passwords (choose anything for dev)
POSTGRES_PASSWORD=changeme
RAG_DB_PASSWORD=changeme_rag
MCP_DB_PASSWORD=changeme_mcp

# API keys (required for MCP web tools)
MCP_API_KEY=any_alphanumeric_string
BRAVE_SEARCH_API_KEY=your_brave_key
JINA_API_KEY=your_jina_key           # optional — free tier works without
```

### 3. Start all services

```bash
cd ai-infrastructure-v1
docker-compose up -d
```

Docker will:
1. Start `ai-database-v1` and initialise the schema + users
2. Start `ai-mcp-server-v1` (waits for DB healthy)
3. Start `ai-rag-llm-client-v1` (waits for DB + MCP healthy)

Check status:
```bash
docker-compose ps
docker-compose logs -f ai-rag-llm-client-v1
```

### 4. Open the UI

| Service | URL |
|---|---|
| RAG client (main UI) | [http://localhost:8000](http://localhost:8000) |
| MCP admin dashboard  | [http://localhost:8001/admin](http://localhost:8001/admin) |

---

## Environment variables reference

All variables live in `ai-infrastructure-v1/.env`. See [.env.example](../ai-infrastructure-v1/.env.example) for defaults.

### Database

| Variable | Description |
|---|---|
| `POSTGRES_USER` | Superuser name (default: `postgres`) |
| `POSTGRES_PASSWORD` | Superuser password |
| `POSTGRES_DB` | Database name (default: `aidb`) |
| `RAG_DB_PASSWORD` | Password for `rag_user` (least-privilege) |
| `MCP_DB_PASSWORD` | Password for `mcp_user` (least-privilege) |
| `POSTGRES_HOST_PORT` | Host-side port binding (default: `5432`) |

### Ollama

| Variable | Description |
|---|---|
| `OLLAMA_BASE_URL` | Ollama URL (default: `http://host.docker.internal:11434`) |
| `OLLAMA_LLM_MODEL` | Generation model (default: `llama3:8b`) |
| `OLLAMA_EMBED_MODEL` | Embedding model (default: `nomic-embed-text`) |
| `EMBEDDING_DIMENSIONS` | Embedding vector width (default: `768`) |

### MCP server

| Variable | Description |
|---|---|
| `MCP_API_KEY` | Auth key for all tool calls |
| `BRAVE_SEARCH_API_KEY` | Brave Search API key |
| `JINA_API_KEY` | Jina Reader API key (optional) |
| `MCP_TOOL_TIMEOUT_SECONDS` | Per-tool timeout (default: `10`) |
| `MCP_HOST_PORT` | Host port (default: `8001`) |

### RAG client

| Variable | Description |
|---|---|
| `RAG_TOP_K` | Default retrieved chunks per query (default: `5`) |
| `RAG_SIMILARITY_THRESHOLD` | Absolute cosine similarity floor (default: `0.20`) |
| `RAG_RELATIVE_THRESHOLD` | Relative drop tolerance (default: `0.20`) |
| `LLM_TIMEOUT` | LLM call timeout in seconds (default: `300`) |
| `DEFAULT_USER_ID` | Default memory user identity (default: `default`) |
| `RAG_HOST_PORT` | Host port (default: `8000`) |

---

## Detailed documentation

- [Architecture deep-dive](docs/architecture.md)
- [ai-database-v1 README](../ai-database-v1/README.md)
- [ai-mcp-server-v1 README](../ai-mcp-server-v1/README.md) · [API reference](../ai-mcp-server-v1/docs/api-reference.md)
- [ai-rag-llm-client-v1 README](../ai-rag-llm-client-v1/README.md)
- [ai-infrastructure-v1 README](../ai-infrastructure-v1/README.md)
