---
description: Run the Vue/Vite frontend dev server for the RAG client locally (hot-reload, port 5173, proxies /api to the backend). Use when asked to start the frontend, do live UI work, or run the Vite dev server.
---

# Stack Frontend Skill

In the Docker stack the Vue SPA is **built into the `ai-rag-llm-client-v1` image**
and served by FastAPI at `http://localhost:8000` — there is no separate frontend
container. Use this skill only for **live UI development**, where you want Vite's
hot-reload dev server instead of rebuilding the image on every change.

The frontend source lives at `ai-rag-llm-client-v1/frontend`. Vite serves on
`http://localhost:5173` and proxies `/api/*` to the backend.

## Start the dev server

```
cd c:/projects/ai-rag-llm-client-v1/frontend && npm install   # first run only
cd c:/projects/ai-rag-llm-client-v1/frontend && npm run dev
```

The backend must already be up (`stack-service` → `ai-rag-llm-client-v1`, or the
full `stack-up`) so the Vite proxy has something to forward `/api` calls to.

## Build the production bundle (what the image serves)

```
cd c:/projects/ai-rag-llm-client-v1/frontend && npm run build
```

This writes `frontend/dist`. To get a built change into the running container,
rebuild the image via the `stack-build` skill
(`docker-compose up -d --build ai-rag-llm-client-v1`).

## After running

Report:
- That Vite is serving on `http://localhost:5173`
- That the proxy works: `curl.exe http://localhost:5173/api/health` should return
  the same payload as the backend's direct `http://localhost:8000/api/health`
- Any Vite compile errors verbatim
