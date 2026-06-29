---
description: Run a Python service's test suite with coverage (pytest). Use when asked to run tests, check test status, or verify nothing is broken. Specify which repo — ai-mcp-server-v1 or ai-rag-llm-client-v1.
---

# Run Tests Skill

Two Python services, each with its own `tests/`. Confirm which one you are
running. Target ≥80% coverage on `services/` per the workspace standard.

## ai-rag-llm-client-v1 (backend)

Code under `backend/app`; `pytest.ini` defines `asyncio_mode = auto` and an
`integration` marker (integration tests need a running Postgres).

Inside Docker:
```
cd c:/projects/ai-infrastructure-v1 && docker-compose exec ai-rag-llm-client-v1 pytest -v --cov=app/services --cov-report=term-missing
```

Natively (deps installed in `backend/.venv`; integration tests skip without a DB):
```
cd c:/projects/ai-rag-llm-client-v1/backend && pytest -v --cov=app/services --cov-report=term-missing
```

Unit only / integration only:
```
docker-compose exec ai-rag-llm-client-v1 pytest -m "not integration" -v
docker-compose exec ai-rag-llm-client-v1 pytest -m integration -v
```

## ai-mcp-server-v1

Tests under `tests/` (test_memory, test_rag, test_auth, test_plugins, …).
```
cd c:/projects/ai-infrastructure-v1 && docker-compose exec ai-mcp-server-v1 pytest -v --cov=. --cov-report=term-missing
```

There is also a live tool smoke harness at
`ai-mcp-server-v1/scripts/smoke_tools.sh` — run it against the running stack when
verifying the MCP tool contract end-to-end, not just unit coverage.

## After running, report

- Total tests passed / failed / skipped (and which repo)
- Overall coverage percentage for the target package
- Any failing test names with their error messages
- Any lines with 0% coverage that look like real gaps worth flagging

> Per the workspace gate, a green pytest is **not** "done" on its own — a live
> smoke test (real app run) is still required before committing.
