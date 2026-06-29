---
description: Build (or rebuild) Docker images for the local stack. Use when asked to build images, rebuild after Dockerfile/requirements/package.json changes, or bring up the stack with --build.
---

# Stack Build Skill

Rebuilds images and starts the stack. Use this after changes to any service's
`Dockerfile`, `requirements.txt`, or the rag-client's `frontend/package.json`
(the Vue SPA is built into the `ai-rag-llm-client-v1` image). Run from the
`ai-infrastructure-v1` repo where the compose file lives.

## Build all and start

```
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d --build
```

## Build a single service

```
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d --build ai-mcp-server-v1
cd c:/projects/ai-infrastructure-v1 && docker-compose up -d --build ai-rag-llm-client-v1
```

## Build without starting

```
cd c:/projects/ai-infrastructure-v1 && docker-compose build
cd c:/projects/ai-infrastructure-v1 && docker-compose build ai-rag-llm-client-v1
```

## After running

Report:
- Whether the build completed without errors (last line per-service should be
  `Successfully tagged ...` or the BuildKit `naming to ...` equivalent)
- Whether containers came up healthy: `docker-compose ps`
- Any new dependency warnings from pip / npm captured during the build

If the build fails on `pip install` or `npm install`, surface the failing
package name + error verbatim — that is the actionable signal.
