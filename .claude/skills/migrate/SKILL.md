---
description: Run Alembic database migrations for the RAG client (upgrade, downgrade, autogenerate, history). Use when asked to migrate the DB, apply migrations, create a new migration, check migration status, or roll back.
---

# Migrate Skill

Application schema changes go through **Alembic, in the `ai-rag-llm-client-v1`
repo** — the Alembic config lives at `backend/migrations/alembic.ini` with
`env.py` beside it. Never alter tables manually.

> The `ai-database-v1` repo is different: it owns the **bootstrap** schema via
> raw `init.sql` + `create_users.sh` (extensions, least-privilege roles, base
> tables created on first DB boot). That is not Alembic territory — edit
> `init.sql` there and reset the DB, don't autogenerate against it.

## Apply pending migrations (most common)

Inside Docker:
```
cd c:/projects/ai-infrastructure-v1 && docker-compose exec ai-rag-llm-client-v1 alembic upgrade head
```

Native (run from where alembic.ini lives):
```
cd c:/projects/ai-rag-llm-client-v1/backend && alembic upgrade head
```

## Create a new migration after model changes

```
docker-compose exec ai-rag-llm-client-v1 alembic revision --autogenerate -m "<short description>"
docker-compose exec ai-rag-llm-client-v1 alembic upgrade head
```

After autogeneration, **always open the generated file under
`backend/migrations/versions/`** and:
- Verify the diff matches the intended change
- Add `op.execute("CREATE EXTENSION IF NOT EXISTS vector;")` if introducing a new
  vector column on a fresh DB
- Use `VECTOR(1024)` for embedding columns (mxbai-embed-large) and add an
  explicit `op.create_index(..., postgresql_using='ivfflat', ...)`
- Preserve the embedding provenance / alignment columns — a model or dimension
  mismatch is meant to fail fast

## Check current migration state

```
docker-compose exec ai-rag-llm-client-v1 alembic current
docker-compose exec ai-rag-llm-client-v1 alembic history --verbose
```

## Roll back

```
docker-compose exec ai-rag-llm-client-v1 alembic downgrade -1          # one step back
docker-compose exec ai-rag-llm-client-v1 alembic downgrade <revision>  # to specific revision
```

## After running, report

- Which revision is now `head` (`alembic current` to confirm)
- Any warnings about pending model changes (`alembic check`)
- If a new migration was created, its file path under
  `backend/migrations/versions/`

> Changing the embedding model is destructive: drop the vector column + ivfflat
> index and re-ingest. The DB is a bind-mount at `E:/Database` — `down -v` does
> not clear it.
