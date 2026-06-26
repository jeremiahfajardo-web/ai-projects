# Feature: Local model selection — hardware-tiered Ollama + startup health-check

## Status
[ ] Spec  [ ] In Progress  [ ] Testing  [ ] Done

_Last updated: 2026-06-26 — initial draft. Lets a client run the **best local model their box can
handle** (not just an 8b/3b flip), pins a chosen model, and fails fast if it isn't there.
**Instance-level** config per the Core/Pack/Instance boundary
([compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md))._

## Problem Statement
Answer quality in Workflow A (and later AI validation) is the chat model. Today the launchers
([start.ps1](../../ai-infrastructure-v1/start.ps1) / `start.sh`) do a **binary** detect — NVIDIA
present → `llama3.1:8b`, else `llama3.2:3b` — with no VRAM sizing, so a client with a 24–48 GB GPU
gets an 8b model when they could run a 14b/32b that answers materially better, and a client can't
**pin** a specific model without editing the launcher. There's also no guard that the configured
chat model was actually pulled/reachable (only embeddings have the startup alignment check), so a
typo'd or unpulled model fails deep in the first query instead of at boot.

This feature: a **VRAM-aware tier ladder** with a sane default per hardware class, an explicit
**pin/override**, and a **chat-model health-check** mirroring the embedding alignment check —
keeping everything local and behind the existing `providers/` seam. Model choice is a fact about
*the customer's hardware*, so it lives at the **Instance** layer, not the Pack.

## Acceptance Criteria
- [ ] On GPU hosts the launcher reads **total VRAM** (`nvidia-smi --query-gpu=memory.total`) and
      selects a default chat model from a documented **tier ladder** (entry / prosumer / workstation /
      server), instead of one fixed `llama3.1:8b`. CPU hosts keep a CPU-safe default.
- [ ] An **explicit `OLLAMA_LLM_MODEL` in `.env` pins** the model — the launcher respects it and
      **skips** auto-detect (so a client can lock a known-good model). Auto-detect only fills an
      unset value. _(Fixes today's behaviour where the launcher unconditionally overrides `.env`.)_
- [ ] `ollama-init` pulls whatever model is selected/pinned (already env-driven) — no hardcoded
      model name in the pull step.
- [ ] **Startup health-check (new):** the MCP server and RAG client verify at lifespan that the
      configured `OLLAMA_LLM_MODEL` is **present in Ollama** (`/api/tags`) and reachable; if not,
      **fail fast** with a clear message naming the model — no silent fallback to a tiny model.
      This sits alongside the existing embedding alignment check.
- [ ] The **embedding model is untouched** by this feature — it stays `mxbai-embed-large` (1024);
      the spec explicitly does **not** add embedding-model tiering (changing it is destructive).
- [ ] `.env.example` documents the ladder (model ↔ approx VRAM ↔ use) and the pin override; a
      short "model vs. hardware" note ships in the infra README.
- [ ] Selecting/pinning a different model requires **no code change** — launcher + `.env` only
      (Instance config).

## Affected Repos / Surfaces
- **ai-infrastructure-v1** (primary): [start.ps1](../../ai-infrastructure-v1/start.ps1) + `start.sh`
  gain VRAM detection + the tier ladder + pin-respect logic; `.env.example` ladder docs; README
  model/hardware guide. No new compose service (`ollama-init` already pulls `OLLAMA_LLM_MODEL`).
- **ai-mcp-server-v1**: add the chat-model presence/reachability check to the lifespan startup
  (next to the embedding alignment check).
- **ai-rag-llm-client-v1**: same lifespan health-check (it also talks to Ollama directly for
  generation).
- **ai-database-v1**: none.

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| `OLLAMA_LLM_MODEL` | str | `.env` (pin) or launcher (auto) | **If set in `.env`, pins** and skips auto-detect; else launcher fills from the ladder |
| GPU total VRAM | int (MiB) | `nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits` | drives the ladder pick when not pinned; absent → CPU default |
| `OLLAMA_EMBED_MODEL` | str | `.env` | **unchanged** — `mxbai-embed-large`, not tiered here |
| `OLLAMA_BASE_URL` | str | `.env` | `http://ollama:11434` (unchanged) |

## Tier ladder (default when not pinned)

| Tier | Detected | Default chat model | Approx VRAM (q4) |
|---|---|---|---|
| CPU | no NVIDIA GPU | `llama3.2:3b` | — (RAM) |
| Entry GPU | < ~16 GB | `llama3.1:8b` | ~6 GB |
| Prosumer GPU | ~16–32 GB | `qwen2.5:14b` (default) / `qwen2.5:32b` (≥24 GB) | ~10 / ~20 GB |
| Workstation | ~32–64 GB | `llama3.3:70b` (q4) | ~40 GB |
| Server | ≥ ~64 GB | `qwen2.5:72b` / 70b full | ~45 GB+ |

_Exact model names + thresholds are a build-time table in the launcher (single source); the
above is the intended shape. Conservative bias — pick a model that fits with headroom, since the
embedder also shares the GPU._

## Outputs / Response Shape
No new endpoint. Two observable signals:
- **Launcher stdout:** which tier was detected and which model was selected/pinned (extends the
  current "GPU detected -> …" line with VRAM + tier).
- **Startup health-check** (extends `/health` semantics): boot proceeds only if the chat model is
  present; otherwise the service exits with a logged, model-named error.
```
[startup] chat model 'qwen2.5:14b' present in Ollama ✓   (embedding 'mxbai-embed-large' 1024 ✓)
[startup] FATAL: chat model 'qwen2.5:99b' not found in Ollama /api/tags — pull it or fix OLLAMA_LLM_MODEL
```

## Data Flow
```
./start.ps1|sh
  → if OLLAMA_LLM_MODEL set in env/.env  → PIN, skip detect
    else → nvidia-smi VRAM query → map to ladder tier → set OLLAMA_LLM_MODEL
  → docker compose up (+ gpu override when GPU present)
       ollama-init: ollama pull $OLLAMA_EMBED_MODEL ; ollama pull $OLLAMA_LLM_MODEL

service lifespan (mcp + rag):
  → existing embedding alignment check (model/dim vs DB)            [unchanged]
  → NEW: GET {OLLAMA_BASE_URL}/api/tags → assert OLLAMA_LLM_MODEL present + reachable
       present → log ✓, continue
       absent / unreachable → log FATAL naming the model, exit non-zero (fail fast)
```

## Schema Impact
**None.** No tables or columns; embedding dimension (1024) and provenance are unchanged. (This
feature deliberately does not touch the embedding model — the destructive path.)

## Seams & Forward-Compatibility
- Uses the existing **`providers/` seam** — selection stays a config concern; a future cloud
  adapter for a client who opts into hosted quality is the same seam, not a rewrite. **Local
  remains the default and the privacy pitch.**
- The tier ladder is the hook for the deferred **vision model** tier (OCR phase): same VRAM→model
  mapping, a parallel `OLLAMA_VISION_MODEL`, when Workflow D lands.
- The health-check generalizes the startup-validation pattern (embeddings → chat → later vision),
  so each added model class fails fast the same way.

## Edge Cases & Error Handling
- **Pinned model not pulled:** health-check fails fast at boot naming the model (don't limp along
  on a default).
- **`nvidia-smi` present but VRAM query fails / returns garbage:** fall back to the entry-GPU
  default (`llama3.1:8b`), log the fallback — never crash the launcher on detection.
- **Multi-GPU host:** v1 uses the single largest GPU's VRAM (or total — build-time decision in
  Open Questions); don't assume model-parallel.
- **Model pulled but Ollama OOMs at inference** (picked too big for real-world headroom): out of
  scope to auto-recover; the conservative ladder + README guidance mitigate. Document the symptom.
- **Embedding model accidentally changed** alongside the chat model: the existing alignment check
  already refuses to boot on dim mismatch — unchanged, and called out in docs as the sticky one.

## Out of Scope for This Feature
- Embedding-model tiering/swapping (destructive; stays fixed at `mxbai-embed-large` 1024).
- Vision/OCR models (deferred Workflow D — seam noted above).
- Cloud LLM adapters (separate `providers/` work).
- Runtime model hot-swap without restart; per-request model choice in the UI.
- Auto-benchmarking / auto-rightsizing the model to measured latency.

## Test Plan
- **Unit (launcher):** given mocked `nvidia-smi` VRAM values, the ladder maps to the expected
  model; a set `OLLAMA_LLM_MODEL` pins and bypasses detection; failed VRAM query → entry-GPU
  fallback.
- **Unit (service):** health-check passes when `/api/tags` lists the model; raises/exits when
  absent or the endpoint is unreachable (mock the Ollama client).
- **Integration:** boot the stack with a pinned valid model → both services pass the check and
  serve; boot with a bogus `OLLAMA_LLM_MODEL` → services fail fast with the named-model error.
- **Manual / verify:** on a real GPU box, confirm the launcher picks the prosumer/workstation
  default and Workflow A answers noticeably better than `llama3.2:3b`.

## Open Questions
- [ ] **Exact ladder thresholds + model names** — validate VRAM footprints against current
      quants (q4_K_M) before locking the table; pick the prosumer default (`qwen2.5:14b` vs jump
      to `:32b` at 24 GB).
- [ ] **Multi-GPU:** size off the largest single GPU (safe) vs. summed VRAM (assumes parallelism)?
      Lean largest-single for v1.
- [ ] **Pull time UX:** 70b q4 is a large first-boot pull — surface progress / a pre-pull step, or
      just document the wait?
- [ ] **Where the launcher's ladder table lives** so PS1 and SH stay in sync (shared data file vs.
      duplicated constant) — avoid drift between the two launchers.
```
