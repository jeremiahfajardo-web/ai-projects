---
description: Start the full local Docker stack (db + ollama + mcp-server + rag-client + n8n) in the background. Use when asked to start the app, bring up the stack, or start all services.
---

# Stack Up Skill

Brings up the whole local stack, detached. The compose file lives in the
`ai-infrastructure-v1` repo, not at the workspace root — always run from there.

```
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d
```

> **GPU:** to use the GPU override (picks `llama3.1:8b` instead of the CPU
> `llama3.2:3b`), add the second file:
> `docker-compose -f docker-compose.yml -f docker-compose.gpu.yml up -d`.
> First boot also runs `ollama-init`, which pulls the models — it can take a
> while before `ai-mcp-server-v1` / `ai-rag-llm-client-v1` pass their healthchecks.

After it returns, verify:

```
cd c:/projects/ai-infrastructure-v1 && docker-compose ps
```

Then report:
- Whether every service shows `Up` / `healthy` (`ollama`, `ai-database-v1`,
  `ai-mcp-server-v1`, `ai-rag-llm-client-v1`, `ai-n8n-v1`; `ollama-init` exits 0)
- MCP server health: `curl.exe http://localhost:8001/health`
- RAG client health: `curl.exe http://localhost:8000/api/health` (also reports
  Ollama + MCP reachability). The Vue UI is served from the same origin at
  `http://localhost:8000`.
- Any container in `Restarting` or `Exited` — surface its logs with
  `docker-compose logs <service>`

If the rag-client `/api/health` shows Ollama or MCP unreachable, the lifespan
startup check is the actionable signal — surface the `RuntimeError` from
`docker-compose logs ai-rag-llm-client-v1`.
