# Setup guide

Step-by-step setup from a clean Windows machine with Docker Desktop and Ollama
already installed.

---

## 1. Install prerequisites

### Docker Desktop
Download from [docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop/).
Start it and ensure the Docker engine is running before proceeding.

```bash
docker --version        # Docker Desktop 4.x
docker compose version  # v2.x
```

### Ollama
Download from [ollama.com/download/windows](https://ollama.com/download/windows).
Install and start from the system tray. Verify:

```bash
curl http://localhost:11434/api/tags
```

Pull the required models:

```bash
ollama pull llama3:8b        # ~4.7 GB — generation model
ollama pull nomic-embed-text # ~274 MB — embedding model
```

Optional: store models on a different drive to save space on C:

```powershell
[System.Environment]::SetEnvironmentVariable("OLLAMA_MODELS", "D:\OllamaModels", "User")
# Restart Ollama from the system tray after setting this
```

---

## 2. Clone the repositories

Clone all repos into the same parent directory (e.g. `D:\projects`):

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

Open `.env` and fill in the required fields:

```ini
# ── Required — passwords (use anything in dev) ──────────────────
POSTGRES_USER=postgres
POSTGRES_PASSWORD=changeme_postgres
POSTGRES_DB=aidb
RAG_DB_PASSWORD=changeme_rag
MCP_DB_PASSWORD=changeme_mcp

# ── Required — MCP authentication ──────────────────────────────
MCP_API_KEY=any_alphanumeric_string_you_choose

# ── Required for web tools — get a free key at brave.com/search/api
BRAVE_SEARCH_API_KEY=your_brave_key

# ── Optional — Jina Reader (free tier works without a key) ──────
JINA_API_KEY=

# ── Ollama (defaults work on Docker Desktop for Windows) ────────
OLLAMA_BASE_URL=http://host.docker.internal:11434
OLLAMA_LLM_MODEL=llama3:8b
OLLAMA_EMBED_MODEL=nomic-embed-text
EMBEDDING_DIMENSIONS=768
```

All other variables have sensible defaults — see `.env.example` for the full
list and explanations.

---

## 4. Start the stack

```bash
cd ai-infrastructure-v1
docker-compose up -d
```

Watch the startup sequence:

```bash
docker-compose logs -f
```

You should see:
1. `ai-database-v1` starts, runs `01_schema.sql` + `02_users.sh`, becomes healthy
2. `ai-mcp-server-v1` starts, connects to DB and Ollama, becomes healthy
3. `ai-rag-llm-client-v1` starts, runs Flask migrations, becomes healthy

Check final status:

```bash
docker-compose ps
# All three services should show "healthy"
```

---

## 5. Verify

```bash
# RAG client health
curl http://localhost:8000/api/health

# MCP server health
curl http://localhost:8001/health

# Ollama (on host)
curl http://localhost:11434/api/tags
```

Open the UIs:

- **RAG client**: http://localhost:8000
- **MCP admin**: http://localhost:8001/admin (enter your `MCP_API_KEY` when prompted)

---

## 6. First use

### Ingest a document

In the RAG client UI, click **Choose file** (or drag-and-drop) and upload a
PDF, Word doc, or any supported file. The document is chunked, embedded, and
stored in the vector DB. Status updates appear in real time.

### Ask a question

Type a question in the query box and click **Ask**. The pipeline panel shows
each step as it runs:
- Memory recall (skipped on first query — no memories yet)
- Knowledge retrieval (shows chunk count)
- Generating... (tokens stream in)
- Saving to memory

### MCP admin

Open http://localhost:8001/admin and enter your `MCP_API_KEY`.

- **Health** tab: per-tool success/error rates and average latency
- **Tool Tester**: run any tool manually with custom JSON params
- **Call Log**: every tool call with input/output

---

## 7. Stopping and restarting

```bash
docker-compose down          # stop containers (data persists in D:/Database)
docker-compose down -v       # stop + delete volumes (WIPES DATABASE)
docker-compose up -d         # restart all services
docker-compose restart ai-rag-llm-client-v1   # restart one service
```

---

## 8. Troubleshooting

### Ollama is unreachable from containers

Verify Ollama is running on the host:
```bash
curl http://localhost:11434/api/tags
```

If it returns nothing, open Ollama from the Windows system tray. Docker
Desktop resolves `host.docker.internal` automatically — no manual host entry
needed.

### Database schema is missing

The init scripts (`01_schema.sql`, `02_users.sh`) only run when the data
volume is first created. If you need to re-initialise:

```bash
docker-compose down -v   # removes the volume — DATA WILL BE LOST
docker-compose up -d
```

### MCP server can't connect to the database

Check that `MCP_DB_PASSWORD` in `.env` matches what `02_users.sh` used.
If you changed the password after first startup, the password won't match.
Re-initialise the volume (above) to reset.

### RAG client shows "no context available"

No documents have been ingested yet. Upload at least one document before
submitting a query. The retrieval step will return empty results and the
LLM will answer from training knowledge only.

### Queries are very slow

`llama3:8b` runs at 10–20 tokens/second on a GPU with 8 GB VRAM. On CPU only
it drops to 1–3 tokens/second.

Ollama runs on the **Windows host** (not inside Docker) and accesses the GPU
directly via Windows drivers — Docker Desktop's GPU settings have no effect here.

Check whether Ollama is actually using your GPU:

```bash
ollama ps        # shows active model and which device it's loaded on (GPU vs CPU)
```

If it shows CPU only, verify the correct drivers are installed on Windows:
- **NVIDIA**: install [CUDA Toolkit](https://developer.nvidia.com/cuda-downloads) — Ollama detects it automatically on next launch
- **AMD**: install [ROCm for Windows](https://rocm.docs.amd.com/en/latest/deploy/windows/index.html)

To squeeze more speed out of your current GPU, set these Windows environment
variables (restart Ollama from the system tray after each change):

```powershell
# Enable Flash Attention — free speedup on supported NVIDIA GPUs
[System.Environment]::SetEnvironmentVariable("OLLAMA_FLASH_ATTENTION", "1", "User")

# Force all model layers onto the GPU (default is already auto/max, but explicit is clearer)
[System.Environment]::SetEnvironmentVariable("OLLAMA_NUM_GPU", "999", "User")
```

Other options:
- Switch to a smaller model: `ollama pull phi3:mini`, update `OLLAMA_LLM_MODEL=phi3:mini`
- Increase `LLM_TIMEOUT` if queries time out before completion (default: 300s)

### ivfflat returns no results

This happens with very small datasets (< 100 rows) if `ivfflat.probes` is at
the default of 1. Both `rag.py` and `tools/vector.py` set
`SET LOCAL ivfflat.probes = 100` before every search query — this is the
expected workaround for dev-scale datasets.
