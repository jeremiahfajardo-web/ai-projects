---
description: Lint and format-check the Python code in a workspace repo (ruff + black). Use when asked to lint, check style, or before committing changes. Specify which repo — ai-mcp-server-v1 or ai-rag-llm-client-v1.
---

# Lint Skill

Both Python services follow the workspace standard: `ruff` + `black` (line
length 88). There are two Python codebases — confirm which one you are linting:

- **ai-mcp-server-v1** — flat layout, code at the repo root (`main.py`,
  `tools/`, `db.py`, …).
- **ai-rag-llm-client-v1** — code under `backend/app`.

## Inside Docker (preferred — deps live in the images)

```
cd c:/projects/ai-infrastructure-v1 && docker-compose exec ai-mcp-server-v1 ruff check .
cd c:/projects/ai-infrastructure-v1 && docker-compose exec ai-mcp-server-v1 black --check .

cd c:/projects/ai-infrastructure-v1 && docker-compose exec ai-rag-llm-client-v1 ruff check .
cd c:/projects/ai-infrastructure-v1 && docker-compose exec ai-rag-llm-client-v1 black --check .
```

## Natively (only if that repo's venv has ruff/black installed)

```
cd c:/projects/ai-mcp-server-v1 && ruff check . && black --check .
cd c:/projects/ai-rag-llm-client-v1/backend && ruff check . && black --check .
```

> Note: the rag-client backend has historically been **ruff-clean but not
> black-formatted**, so `black --check` may report files needing reformatting
> even when ruff is green. Confirm with the user before running `black .` to
> rewrite them.

## Auto-fix

```
docker-compose exec <service> ruff check . --fix   # safe fixes only
docker-compose exec <service> black .              # rewrites files
```

## After running, report

- Whether ruff found violations (file, line number, rule code)
- Whether black found files needing reformatting
- If clean: confirm "All lint and format checks passed" for that repo
- If issues found: list them and ask whether to auto-fix
