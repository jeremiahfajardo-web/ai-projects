# Setup guide

Step-by-step setup from a clean Windows machine. Ollama is **containerised** — you do
**not** install it on the host or pull models by hand. The authoritative, detailed setup
lives in [ai-infrastructure-v1/README.md](../../ai-infrastructure-v1/README.md); this is the
condensed walkthrough.

---

## 1. Install prerequisites

### Docker Desktop
Download from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/),
start it, and confirm the engine is running:

```bash
docker --version        # Docker Desktop 4.x
docker compose version  # v2.x
```

### (Optional) NVIDIA GPU
For GPU acceleration, install an NVIDIA driver + the **Container Toolkit**. The launcher
auto-detects it and selects `llama3.1:8b`; without a GPU the stack falls back to
`llama3.2:3b` on CPU. **No host Ollama install is required either way** — it runs in a
container and pulls its own models.

---

## 2. Clone the repositories

Clone all repos into the same parent directory (e.g. `C:\projects`):

```bash
git clone <url>/ai-infrastructure-v1
git clone <url>/ai-database-v1
git clone <url>/ai-mcp-server-v1
git clone <url>/ai-rag-llm-client-v1
git clone <url>/ai-projects
```

The `docker-compose.yml` in `ai-infrastructure-v1` uses relative paths
(`../ai-database-v1`, etc.) so all repos must share the same parent directory.

---

## 3. Configure environment

```bash
cd ai-infrastructure-v1
cp .env.example .env
```

Fill in every `changeme` value. The Ollama settings have working defaults (containerised) —
you normally don't touch them.

```ini
# ── Required — passwords (use anything in dev) ──────────────────
POSTGRES_PASSWORD=changeme_postgres
RAG_DB_PASSWORD=changeme_rag
MCP_DB_PASSWORD=changeme_mcp

# ── Required — MCP authentication ──────────────────────────────
MCP_API_KEY=any_alphanumeric_string_you_choose

# ── Required — isolated n8n ────────────────────────────────────
N8N_ENCRYPTION_KEY=generate_a_random_key   # must differ from any existing n8n
N8N_HOST_PORT=5679                         # set if you already run n8n on 5678

# ── Required for web tools — free key at brave.com/search/api ──
BRAVE_SEARCH_API_KEY=your_brave_key
JINA_API_KEY=                              # optional — free tier works without

# ── Ollama (containerised; defaults shown — usually leave as-is) ─
OLLAMA_BASE_URL=http://ollama:11434
OLLAMA_EMBED_MODEL=mxbai-embed-large
EMBEDDING_DIMENSIONS=1024
# OLLAMA_LLM_MODEL is selected by the launcher (llama3.1:8b GPU / llama3.2:3b CPU)

# ── Optional — cloud LLM demo (embeddings always stay local) ────
# LLM_PROVIDER=anthropic
# ANTHROPIC_API_KEY=sk-ant-...
```

All other variables have sensible defaults — see `.env.example` for the full list.

---

## 4. Start the stack

```powershell
./start.ps1     # Windows — probes nvidia-smi, picks the LLM model, runs compose up --build
```
```bash
./start.sh      # Linux / macOS
```

Watch the startup sequence:

```bash
docker compose logs -f
```

You should see:
1. `ollama` starts; `ollama-init` pulls the embed + LLM models, then exits `0`
   (first run only — several minutes; watch `docker compose logs -f ollama-init`)
2. `ai-database-v1` starts, runs the init schema + user creation, becomes healthy
3. `ai-mcp-server-v1` starts (waits on DB + ollama-init), becomes healthy
4. `ai-rag-llm-client-v1` starts (waits on DB + MCP), runs Alembic migrations, becomes healthy
5. `ai-n8n-v1` starts (isolated)

```bash
docker compose ps     # long-running services show "healthy"; ollama-init is gone (exited 0)
```

> Bare `docker compose up -d` works but skips GPU detection (uses the CPU-safe model). Use
> the launcher to get GPU acceleration.

---

## 5. Verify

```bash
curl http://localhost:8000/api/health   # RAG client
curl http://localhost:8001/health       # MCP server
curl http://localhost:11434/api/tags    # Ollama (containerised; port mapped to host)
```

Open the UIs:
- **RAG client**: http://localhost:8000
- **MCP admin**: http://localhost:8001/admin (enter your `MCP_API_KEY`)
- **n8n**: http://localhost:5678 (or `N8N_HOST_PORT`)

---

## 6. First use

### Ingest a document
In the RAG client UI, choose or drag-drop a PDF, Word doc, or other supported file. It is
chunked (structure-aware parent/child), embedded, and stored in the vector DB, with live
status updates.

### Ask a question
Type a question and click **Ask**. The pipeline panel shows each step:
- Knowledge retrieval (shows chunk count)
- Generating... (tokens stream in; any **tool calls** the model makes appear as rows)
- Saving to memory

Use the **tool selector** under the query box to choose which MCP tools the model may use
this turn — deselect all for a pure-RAG (local-only) answer, or enable web/memory tools to
watch the model reach out live.

### MCP admin
Open http://localhost:8001/admin and enter your `MCP_API_KEY`:
- **Health**: per-tool success/error rates and latency
- **Tool Tester**: run any tool manually with custom JSON params
- **Call Log**: every tool call with input/output

---

## 7. Stopping and restarting

```bash
docker compose down                 # stop (data persists in the DB bind-mount)
docker compose restart ai-rag-llm-client-v1   # restart one service
./start.ps1                         # restart all (with GPU detection)
```

Wiping the database is a manual bind-mount delete — see the **Clean restart** section in the
[root README](../README.md). `docker compose down -v` does **not** clear a bind-mount.

---

## 8. Troubleshooting

### Ollama / models not ready
Ollama is a container now. Check the model pull finished:
```bash
docker compose logs ollama-init     # should end with the models pulled and exit 0
docker compose ps                   # ai-ollama-v1 should be "healthy"
curl http://localhost:11434/api/tags
```
The app services wait on `ollama-init` completing, so a missing-model crash usually means the
pull failed (network) — re-run `./start.ps1`.

### Database schema is missing
The init scripts only run when the data dir is first created. Re-initialise by wiping the
bind-mount (see root README) and starting again.

### MCP server can't connect to the database
Ensure `MCP_DB_PASSWORD` in `.env` matches what user creation used on first init. If you
changed it after first startup, wipe + re-init the data dir.

### RAG client shows "no context available"
No documents ingested yet — upload at least one. Retrieval returns empty and the LLM answers
from training knowledge only.

### Queries are very slow
`llama3.1:8b` runs ~10–20 tok/s on an 8 GB GPU; CPU `llama3.2:3b` is far slower. Confirm GPU
use:
```bash
docker exec ai-ollama-v1 ollama ps    # shows the model and GPU vs CPU placement
```
If CPU-only on a GPU host, ensure the NVIDIA Container Toolkit is installed and you launched
via `./start.ps1` (which layers `docker-compose.gpu.yml`). Options: a smaller model, or raise
`LLM_TIMEOUT`.

### ivfflat returns no results
On very small datasets (< 100 rows) with `ivfflat.probes=1`, the index searches one cluster.
Both `rag.py` and `tools/vector.py` set `SET LOCAL ivfflat.probes = 100` before each search —
the expected dev-scale workaround.
