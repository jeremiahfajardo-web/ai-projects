---
description: Start (or restart) a single backend service in the local stack — the MCP server, the RAG client, the database, or Ollama. Use when asked to start/restart one service rather than the whole stack.
---

# Stack Service Skill

Brings up one service (and its compose dependencies, started automatically).
Unlike the source single-repo stack there is **no separate `frontend`
container** here — the Vue SPA is served by `ai-rag-llm-client-v1` at
`http://localhost:8000`. For the live Vite dev server, use the `stack-frontend`
skill instead.

Services: `ai-database-v1` (:5432), `ai-mcp-server-v1` (:8001),
`ai-rag-llm-client-v1` (:8000), `ollama` (:11434), `ai-n8n-v1` (:5678).

## Start / restart a service

```
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d ai-mcp-server-v1
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d ai-rag-llm-client-v1
```

After it returns, verify (substitute the service name):

```
cd c:/projects/ai-infrastructure-v1 && docker-compose ps ai-mcp-server-v1
cd c:/projects/ai-infrastructure-v1 && docker-compose logs --tail=50 ai-mcp-server-v1
```

Health checks:
- `ai-mcp-server-v1`:    `curl.exe http://localhost:8001/health`
- `ai-rag-llm-client-v1`: `curl.exe http://localhost:8000/api/health`

## After running

Report:
- Whether the container shows `Up` / `healthy`
- The last log line (uvicorn ready / lifespan complete) — or any startup error
- The `/health` (mcp) or `/api/health` (rag) response: provider config + Ollama
  and MCP reachability

If a lifespan check fails (Ollama unreachable, embedding model/dimension
mismatch, missing API key for a selected provider), surface the `RuntimeError`
from the logs verbatim — it is the actionable signal.
