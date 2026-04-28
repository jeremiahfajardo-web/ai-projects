# Architecture deep-dive

## 1. Repository layout

```
ai-projects/              ← this repo (documentation only)
ai-infrastructure-v1/     ← docker-compose + shared .env
ai-database-v1/           ← PostgreSQL schema + user bootstrap
ai-mcp-server-v1/         ← MCP tool server (FastAPI)
ai-rag-llm-client-v1/     ← RAG client (Flask + Vue 3)
```

Each component repo is independently deployable. The infrastructure repo wires
them together. No repo imports code from another — all cross-service
communication is HTTP.

---

## 2. Database schema

Managed by `ai-database-v1`. All vector columns use `VECTOR(768)` matching
`nomic-embed-text`'s output.

```
┌─────────────────────────────────────────────────────────────────┐
│ documents           ← ingested files                            │
│   id (uuid)                                                     │
│   filename, file_size, mime_type, status                        │
│   chunk_count                                                   │
└────────────────────────┬────────────────────────────────────────┘
                         │ 1:N
┌────────────────────────▼────────────────────────────────────────┐
│ document_chunks     ← text chunks with embeddings               │
│   id (uuid)                                                     │
│   document_id (fk)                                              │
│   chunk_index, content, token_count                             │
│   embedding VECTOR(768)          ← pgvector cosine search       │
│   search_vector TSVECTOR (gen'd) ← BM25 keyword search          │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ memory_embeddings   ← user memories from MCP memory_write       │
│   id (bigint)                                                   │
│   user_id, session_id                                           │
│   content, memory_type (episodic|semantic|working|procedural)   │
│   importance_score, ttl_days                                    │
│   embedding VECTOR(768)                                         │
│   search_vector TSVECTOR (gen'd)                                │
│   pending_delete (for two-phase delete gate)                    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ web_cache           ← MCP web_crawl_and_store results           │
│   url (unique), content, chunk_index                            │
│   embedding VECTOR(768)                                         │
│   search_vector TSVECTOR (gen'd)                                │
│   fetched_at, ttl_hours                                         │
└─────────────────────────────────────────────────────────────────┘

┌───────────────────┐  ┌───────────────────┐  ┌──────────────────┐
│ sessions          │  │ turns             │  │ user_facts       │
│ mcp_tool_calls    │  │ trusted_sources   │  │ error_log        │
└───────────────────┘  └───────────────────┘  └──────────────────┘
```

### Indexes

| Table | Index type | Column | Purpose |
|---|---|---|---|
| `document_chunks` | ivfflat (lists=100) | `embedding` | pgvector ANN search |
| `document_chunks` | GIN | `search_vector` | tsvector keyword search |
| `memory_embeddings` | ivfflat (lists=100) | `embedding` | memory recall |
| `memory_embeddings` | GIN | `search_vector` | keyword memory search |
| `web_cache` | ivfflat (lists=100) | `embedding` | web content search |

> **ivfflat probe setting:** Dev datasets (< 100 rows) require
> `SET LOCAL ivfflat.probes = 100` on each query — otherwise the index
> searches only 1 of 100 clusters and misses everything. This is set at
> query time in `rag.py` and `tools/vector.py`.

### Least-privilege users

| User | Tables | Permissions |
|---|---|---|
| `rag_user` | `document_chunks`, `documents`, `sessions`, `turns`, `memory_embeddings`, `user_facts`, `error_log` | SELECT, INSERT, UPDATE |
| `mcp_user` | `document_chunks`, `documents` (read) + `memory_embeddings`, `mcp_tool_calls`, `trusted_sources`, `web_cache`, `error_log` | SELECT on documents/chunks; SELECT, INSERT, UPDATE, DELETE on memory + web_cache |

Users are created by `create_users.sh` (a shell script, not SQL) because
PostgreSQL init scripts run as the superuser and cannot read Docker env vars
via `current_setting()`.

---

## 3. MCP server (ai-mcp-server-v1)

FastAPI application exposing 12 tools over authenticated HTTP.

### Auth model

Every tool request must carry `X-MCP-API-Key`. The key maps to a permission
tier; each tool declares its minimum required tier:

```
read   → document_search, vector_db_query, get_trusted_sources, web_search,
          web_fetch_cached, memory_read, memory_list
write  → web_scrape, web_crawl_and_store, memory_write,
          memory_summarize_session
delete → memory_delete
```

Permission tiers are cumulative: a `write` key can also call `read` tools.

### Tool execution

Every tool is wrapped by `run_tool()`:

```python
async def run_tool(name, coro, pool, session_id, user_id):
    try:
        result = await asyncio.wait_for(coro, timeout=settings.mcp_tool_timeout_seconds)
        status = "success"
    except asyncio.TimeoutError:
        result = None; status = "timeout"
    except Exception as exc:
        result = None; status = "error"
    await log_tool_call(pool, name, status, ...)
    return result
```

Per-tool timeout (default 120s — raised from 10s to accommodate web_crawl_and_store)
prevents any single slow tool from blocking the server. Status is logged to
`mcp_tool_calls` for the admin dashboard.

### Hybrid search (RRF)

`document_search`, `vector_db_query`, and `memory_read` use Reciprocal Rank Fusion to merge
pgvector cosine rankings and tsvector keyword rankings:

```
score(doc) = Σ  1 / (k + rank_i)    k=60 (Cormack et al., 2009)
```

k=60 smooths rank differences so a document appearing in both lists outscores
one appearing in only one, without requiring score normalisation across the two
incompatible scales (cosine similarity vs. BM25 rank).

### Two-phase delete

`memory_delete` uses a confirmation gate to prevent LLM-triggered accidental
data loss:

```
First call  (confirmed=false) → sets pending_delete=True
Second call (confirmed=true)  → hard DELETE
```

This ensures a misfire from an LLM tool call won't permanently delete data
without explicit human confirmation.

---

## 4. RAG client (ai-rag-llm-client-v1)

Flask + Vue 3 application with a four-step agentic query pipeline.

### Agentic pipeline

```
POST /api/query/stream
  │
  ├─ 1. memory_read   → MCP /tools/memory_read (skipped if MCP unconfigured)
  │      Returns top-5 memories semantically related to the query;
  │      filtered client-side by RAG_SIMILARITY_THRESHOLD (default 0.20)
  │
  ├─ 2. retrieve      → MCP /tools/document_search (when MCP configured)
  │      Hybrid pgvector + BM25 search on document_chunks, logged in MCP admin
  │      Fallback: direct rag.retrieve() when MCP unavailable
  │      Filtered by RAG_SIMILARITY_THRESHOLD (absolute) +
  │                    RAG_RELATIVE_THRESHOLD (relative to top chunk)
  │
  ├─ 3. generate      → Ollama /api/chat with tool definitions (up to 5 turns)
  │      LLM may call: document_search, web_search, web_crawl_and_store, web_fetch_cached
  │      Each tool call dispatched via MCPClient → result appended to message history
  │      System prompt = memories + retrieved chunks
  │      Tokens streamed to browser via SSE
  │
  └─ 4. memory_write  → MCP /tools/memory_write (skipped if MCP unconfigured)
         Stores "User asked X / Assistant answered Y" as episodic memory
```

### SSE streaming architecture

Flask/Werkzeug cannot yield from an async generator. The streaming endpoint
uses a Queue + Thread pattern:

```
sync Flask route handler
  │
  ├── captures config snapshot (current_app proxy is not thread-safe)
  ├── spawns daemon Thread
  │     Thread: new asyncio event loop + app_context
  │             runs _agentic_flow() → puts events into queue.Queue
  │
  └── returns Response(generate(), content_type='text/event-stream')
        generate() is a sync generator that reads from queue
        yields "data: {...}\n\n" until sentinel None is received
```

### Similarity filtering

**Document chunks (two-stage, applied inside MCP document_search):**

1. **Absolute floor** (`RAG_SIMILARITY_THRESHOLD`, default 0.20): discard any
   chunk whose cosine similarity is below this value regardless of context.

2. **Relative floor** (`RAG_RELATIVE_THRESHOLD`, default 0.20): of the
   remaining chunks, discard any whose score is more than 0.20 points below
   the top-scoring chunk. Prevents over-retrieval in topically tight document
   sets where all chunks score in a narrow band (e.g. 0.55–0.70) and the
   absolute floor alone admits too many weakly-related chunks.

Both thresholds are configurable per-request via the query API and per-session
via the UI dropdowns (0.05–0.95, step 0.05).

**Memories (single-stage, applied client-side after memory_read):**

`memory_read` returns the top-k rows by cosine proximity with no server-side
score floor. The RAG client applies `RAG_SIMILARITY_THRESHOLD` as an absolute
floor immediately after receiving results, so low-relevance memories from
unrelated prior conversations are discarded before they reach the system prompt.

### Document ingestion

```
POST /api/ingest (multipart/form-data)
  │
  ├── file type detection by MIME + extension
  ├── text extraction:
  │     PDF    → pdfplumber
  │     DOCX   → python-docx
  │     XLSX   → openpyxl
  │     PPTX   → python-pptx
  │     HTML   → BeautifulSoup4
  │     MD/TXT → raw read
  ├── chunking: 512 tokens, 50 token overlap (LangChain splitter)
  ├── embedding: Ollama nomic-embed-text → 768-dim vector per chunk
  └── INSERT document_chunks (embedding cast to VECTOR(768))
```

---

## 5. Infrastructure (ai-infrastructure-v1)

Single `docker-compose.yml` with three services on the `ai-project` bridge
network.

### Startup order

```
ai-database-v1    → healthcheck: pg_isready (every 10s)
                         │
ai-mcp-server-v1  → depends_on: database (healthy)
                    healthcheck: curl /health (every 15s)
                         │
ai-rag-llm-client → depends_on: database (healthy) + mcp-server (healthy)
```

The RAG client waits for MCP to be healthy before starting, ensuring memory
tools are available from the first request.

### Volume

The database data directory is mounted at the path in `DB_DATA_PATH` (currently `E:/Database`) on the host. This
persists data across `docker-compose down` / `up` cycles. Change the path in
`docker-compose.yml` to suit your drive layout.

### Host networking

Ollama runs natively on Windows (not in Docker) and is accessed from containers
via `host.docker.internal:11434`. Docker Desktop resolves this hostname
automatically on Windows and Mac.

---

## 6. Key design decisions

**Local-only inference** — Ollama eliminates cloud API costs and data privacy
concerns. `llama3:8b` + `nomic-embed-text` run well on a consumer GPU (8 GB
VRAM) or CPU (slower).

**Flask over FastAPI for the RAG client** — The existing codebase was Flask;
switching frameworks mid-project would break migrations and test infrastructure
without proportional benefit. `flask[async]` provides native async route
support.

**asyncpg + pgvector codec (MCP server)** — `register_vector` from the
`pgvector` package handles `VECTOR` type serialisation natively. No string
formatting of embedding arrays is needed for reads; only INSERT/UPDATE
casts require `CAST($1 AS vector)`.

**Queue + Thread SSE pattern (RAG client)** — Werkzeug's WSGI server cannot
yield from async generators. A sync generator reading from a `queue.Queue`
written by a background asyncio thread gives SSE streaming without requiring
an ASGI server swap.

**ivfflat over HNSW** — ivfflat was available in pgvector first, integrates
well with dev-scale datasets (< 10k rows), and the `probes=100` workaround for
small datasets is understood and documented. HNSW is faster at larger scale;
migration is straightforward if needed.

**Two-phase memory delete** — LLM-driven tool calls can misfire. Requiring
`confirmed=true` on a second distinct call prevents any single-step LLM action
from permanently deleting user data.

**Shell script user creation** — PostgreSQL `EXECUTE` in SQL init scripts
cannot read Docker environment variables. A Bash heredoc calling `psql`
directly reads `$RAG_DB_PASSWORD` and `$MCP_DB_PASSWORD` from the container
environment at startup.

**RRF k=60** — The value from Cormack et al. (2009) works well across a wide
range of result set sizes. It smooths rank differences enough that a document
appearing in both semantic and keyword results reliably outscores one appearing
in only one, without tuning needed per dataset.
