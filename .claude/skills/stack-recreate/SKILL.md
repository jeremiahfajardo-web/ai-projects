---
description: Force-recreate Docker containers in the local stack (drops and re-runs them with current config). Use when asked to force recreate, recreate containers, or apply .env changes that need a fresh container.
---

# Stack Recreate Skill

Force-recreates containers from the current config. The shared `.env` lives in
`ai-infrastructure-v1` alongside the compose file. Use this when:
- `.env` values changed and the running containers were started before the change
- A container is in a wedged state and a plain restart is not clearing it

## Force recreate all

```
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d --force-recreate
```

## Force recreate a single service

```
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d --force-recreate ai-mcp-server-v1
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d --force-recreate ai-rag-llm-client-v1
```

## Force recreate AND rebuild

The Vue SPA is baked into the `ai-rag-llm-client-v1` image at build time, so any
change that must reach the served frontend needs `--build`, not just a recreate:

```
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d --build --force-recreate ai-rag-llm-client-v1
```

## After running

Report:
- Each affected container's new status (`docker-compose ps`)
- Whether the lifespan / startup logs are clean (`docker-compose logs --tail=30 <service>`)
- For `ai-mcp-server-v1`: confirm `curl.exe http://localhost:8001/health`
- For `ai-rag-llm-client-v1`: confirm `curl.exe http://localhost:8000/api/health`
  returns the expected provider config + Ollama/MCP reachability

> **This does NOT delete the database.** The DB is a bind-mount at `E:/Database`;
> even `docker-compose down -v` does not clear it. For a destructive reset, wipe
> `E:/Database/*` manually — never from this skill.
