# Feature: Cross-encoder reranker (precision stage over the wide candidate pool)

## Status
[x] Spec  [x] In Progress  [ ] Testing  [ ] Done

_Implementation note (2026-06-28): built + unit-tested across **both retrieval paths** — the
rag-client direct path (`providers/reranker.py` + `services/rag._rerank_candidates`) **and** the MCP
`document_search` mirror (`ai-mcp-server-v1/reranker.py`, same seam). FlashRank local default,
flag-off by default, graceful RRF fallback. `rerank_score` propagates through both `_collapse_to_parents`
and is surfaced as a **UI badge** (`ResponsePanel.vue`). A **startup warmup health-check**
(`warmup_reranker`) reports a bad `RAG_RERANK_MODEL` at boot without failing retrieval, and the
per-call path logs a warning + falls back to RRF if the reranker becomes unavailable. Remaining before
Done: **live latency smoke** on the running stack and the **default-on tier** decision (Docker was down
this session, so no live run yet)._

_Last updated: 2026-06-28 — initial draft + provider direction decided (config-switchable seam,
default FlashRank/ONNX standalone, `ollama`/cloud selectable via `.env`). The follow-on reserved by
[parent-child-retrieval.md](parent-child-retrieval.md) ("Reranker (next spec): drops in between
'RRF over wide pool' and 'collapse to parents'"). Local-by-default, behind a `providers/` reranker
seam mirroring the embedding/LLM adapters. **No schema impact.**_

## Problem Statement
Parent/child retrieval fixed *recall* — the right passage now reaches the candidate pool — but the
final ordering handed to the LLM is still **RRF**, a query-blind rank fusion. RRF only knows *where*
a chunk ranked in the semantic and keyword lists; it never reads the query against the passage, so a
lexically-noisy distractor can outrank the genuinely best passage, and the `FINAL_K` parents the LLM
sees include avoidable filler. A cross-encoder reranker reads each `(query, passage)` pair jointly
and produces a true relevance score, so the few parents that reach the model are the *most relevant*
ones — the highest-leverage remaining RAG-quality lever per the retrieval backlog (the chunking and
candidate-pool root causes are already shipped).

The seam already exists: [rag.py:122-130](../ai-rag-llm-client-v1/backend/app/services/rag.py#L122)
fuses to a wide `candidate_k` pool of children, then immediately collapses to parents. The reranker
re-orders that pool **before** collapse, using the wide net as its input — no other pipeline change.

## Motivating Case (tunes the defaults)
Same `CED3.1_Maintenance_Guideline` corpus. A query like *"what label do mislabeled racks get?"*
pulls, into the candidate pool, several children that share the tokens "label"/"rack" (BR LABEL
defaults, rack enumeration) ahead of the child that actually states the mislabeled-rack rule — RRF
ranks on token overlap, so the precise answer can sit at rank 4–6 and, after parent-collapse + a
small `FINAL_K`, either lands mid-context or drops out. A cross-encoder scoring each child against
the full question pushes the answer-bearing child to rank 1, so its parent section is `FINAL_K[0]`.

## Acceptance Criteria
- [ ] **Reranks the post-fusion pool:** after `_merge_rrf` (or the single-mode candidate list), the
      candidates are reordered by a cross-encoder `(query, child.content)` relevance score **before**
      `_collapse_to_parents`; the returned parents reflect reranked child order.
- [ ] **Local by default, no cloud key:** the default reranker runs on-device and needs no API key —
      consistent with the "truly local" stack. An opt-in cloud reranker (e.g. Cohere/Jina rerank) is
      reachable through the same seam, additive, exactly like the cloud LLM adapter.
- [ ] **Flag-reversible:** `RAG_RERANK_ENABLED=false` restores byte-for-byte current behaviour (RRF
      order straight into collapse). The stage is purely additive and can be turned off.
- [ ] **Graceful degradation:** if the reranker model is unavailable, errors, or times out, retrieval
      **falls back to RRF order**, logs a warning, and never fails the query (mirrors the MCP-down and
      keyword-zero-lexeme degradations already in the pipeline).
- [ ] **Latency budget:** reranking a `candidate_k`≈40 pool stays within a documented budget on the
      CPU tier (target ≪ the model's own generation time); an input cap (`RAG_RERANK_INPUT_K`) bounds
      worst-case cost. Measured numbers recorded in the spec before default-on.
- [ ] **All modes:** runs on whatever candidate list a mode produces (hybrid / semantic / keyword) —
      it reorders an existing list, independent of how the list was built.
- [ ] **Deterministic:** same `(query, candidates)` ⇒ same order (a cross-encoder is deterministic,
      unlike an LLM-as-reranker — a deliberate reason for this design).
- [ ] **Citations/UI intact:** the reranked score is surfaced for display/debug while
      `matched_child_ids`, `doc_id`, and parent resolution keep working; the source-citation UI is
      untouched.
- [ ] **Both retrieval paths agree** *(or MCP path explicitly deferred — see Open Questions):* the
      RAG client `retrieve()` and the MCP `document_search` either both rerank or the divergence is
      documented, matching the parent-collapse precedent that the two paths stay in lockstep.

## Affected Repos / Surfaces
- **ai-rag-llm-client-v1** (primary):
  [services/rag.py](../ai-rag-llm-client-v1/backend/app/services/rag.py) — insert a `rerank()` call
  between fusion and `_collapse_to_parents`; thread config + graceful fallback. New
  `app/providers/reranker.py` (+ factory entry) mirroring
  [providers/factory.py](../ai-rag-llm-client-v1/backend/app/providers/factory.py) and the embedding
  provider. Optional: surface a `rerank_score` in the result dict for the UI/debug panel.
- **ai-mcp-server-v1**: [tools/rag.py](../ai-mcp-server-v1/tools/rag.py) `document_search` — mirror
  the rerank step so both retrieval paths agree (or defer; see OQ).
- **ai-infrastructure-v1**: new `.env` defaults (`RAG_RERANK_*`); if the local reranker runs as a
  dedicated container, a compose service + its model pull (mirrors `ollama` / `ollama-init`).
- **ai-database-v1**: none — reranking is in-memory reordering, **no schema change**.

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| `RAG_RERANK_ENABLED` | bool | config | default decided after latency validation (likely `true` on GPU, `false`/flagged on CPU tier) |
| `RAG_RERANK_PROVIDER` | str | config | `local` (default — FlashRank/ONNX, **off** the Ollama runtime) \| `ollama` (LLM-as-reranker — selectable but slow + thrashes model loads) \| `cohere`/`jina` (cloud, opt-in) \| `none` |
| `RAG_RERANK_MODEL` | str | config | local model id (recommended default below); pinned + health-checked like the embedding model |
| `RAG_RERANK_INPUT_K` | int | config | max candidates fed to the reranker (latency cap), e.g. 40; pool truncated to this before scoring |
| `query` | str | route | the raw user query (same text used for embedding/keyword) |
| `candidates` | list[dict] | `_merge_rrf` / single-mode search | child dicts (`chunk_id`, `content`, `parent_chunk_id`, scores) |

## Outputs / Response Shape
No new endpoint shape. The candidate list is reordered and each item carries the reranker score
alongside the existing fields (so the collapse + citation logic is unchanged):
```json
{ "chunk_id": "uuid", "doc_id": "uuid", "parent_chunk_id": "uuid",
  "content": "…child text…", "similarity_score": 0.0167, "search_type": "hybrid",
  "rerank_score": 8.42 }
```
`similarity_score`/`search_type` are preserved for the existing UI badge; `rerank_score` is the new
ordering signal (and the field `_collapse_to_parents` reads for best-child-rank).

## Data Flow
```
retrieve (hybrid):
  embed(query)
  → child semantic top CANDIDATE_K + child keyword top CANDIDATE_K
  → _merge_rrf  → ranked candidate pool (≤ candidate_k)
  → rerank(query, pool[:RERANK_INPUT_K])           # NEW: cross-encoder (query,passage) scores
        via providers/reranker  (local default | cloud opt-in)
        on error/unavailable → return pool unchanged + log   # graceful fallback
  → _collapse_to_parents(reranked_pool, top_k)     # collapse now follows rerank order
  ← parents (with matched_child_ids, rerank_score)
```
Single-mode (`semantic`/`keyword`) is identical minus the RRF merge — the same `rerank()` runs on
that mode's candidate list.

## Schema Impact
**None.** No tables/columns/migration; reranking reorders in-memory results. (The reranker model is a
runtime artifact, pulled/loaded at startup — not persisted state.)
- Ownership: n/a — no new table.
- Provenance: n/a — no new vector column. (The reranker does not embed; it scores pairs.)

## Seams & Forward-Compatibility
- **`providers/reranker` seam** mirrors the embedding + LLM provider seams: a `Reranker` protocol
  with `rerank(query, passages) -> list[score]`, a `local` implementation as the no-key default, and
  cloud/Ollama adapters selected by `RAG_RERANK_PROVIDER` — additive, exactly the cloud-LLM pattern
  ([cloud-provider-adapter.md](../ai-rag-llm-client-v1/docs/features/cloud-provider-adapter.md)). The
  backend is a pure `.env` switch; no pipeline change between providers.
- **Why `local` (FlashRank/ONNX) is the default, not an Ollama reranker:** Ollama serves embeddings +
  generation, **not** a cross-encoder rerank endpoint, so an "Ollama reranker" is really
  *LLM-as-reranker* — generative, non-deterministic, and the weak local chat model doing the judging.
  It also **thrashes model loads**: on a single-GPU box Ollama evicts the chat model to load the
  reranker, scores, then reloads the chat model to generate — two extra load/unload cycles per query
  (or simultaneous VRAM for both, which entry/prosumer tiers lack). FlashRank runs on CPU via
  `onnxruntime`, **off the Ollama runtime entirely**, so it scores concurrently while the chat model
  stays resident — no swap thrash. The `ollama` provider stays *selectable* for a zero-extra-dep
  setup, with this cost documented.
- **First concrete RAG pipeline-step** plugged into the Phase 4 deferred pipeline-step hook
  ([phase4-plugin-sdk-n8n.md](phase4-plugin-sdk-n8n.md) OQ#5) — the rerank stage is the reference
  implementation of "an optional, swappable step between fusion and collapse."
- **Two-stage option reserved:** scoring *children* (cheap, fits a cross-encoder's short context) is
  the default; a later "rerank the collapsed *parents*" pass can be added behind the same flag for
  holistic queries without re-architecting (see OQ).
- **Instance/Pack tuning:** model choice + enabled-state are config, so per-customer hardware tiers
  and per-vertical quality/latency trade-offs are value changes, consistent with the Core/Pack/
  Instance boundary ([compliance-platform-core-pack-boundary.md](compliance-platform-core-pack-boundary.md)).

## Edge Cases & Error Handling
- **Empty / single candidate:** skip reranking, return as-is (no model call).
- **Reranker unavailable / errors / times out:** log a warning, return the RRF (or single-mode)
  order unchanged — the query still answers. A startup health-check (mirroring the embedding
  alignment check) warns if the pinned reranker model isn't loadable, rather than failing deep in the
  first query.
- **Passage longer than the reranker's max sequence length:** truncate to the model limit before
  scoring (children are already ~350 tok, so this is rare; parents, if reranked later, are not).
- **Large `candidate_k`:** truncate to `RAG_RERANK_INPUT_K` before scoring to bound latency; pool
  beyond the cap keeps its RRF order behind the reranked head.
- **CPU tier latency:** if reranking pushes total response time past an acceptable budget, ship
  flag-off on CPU and on by default on GPU (the same hardware-tiering as model selection).
- **Score scale:** reranker scores are model-specific (logits, not 0–1) — used only for *ordering*;
  the displayed confidence badge keeps using the existing `search_type`/`similarity_score`.

## Out of Scope for This Feature
- **LLM-as-reranker as the *default*** — the `ollama` provider (generative scoring via the chat
  model) is *selectable* for a zero-extra-dependency setup, but it is explicitly **not** the default
  (slow, non-deterministic, model-load thrashing — see Seams). Building a *true* cross-encoder on the
  Ollama runtime is out of scope: Ollama has no rerank endpoint.
- **Reranking parents instead of / in addition to children** — seam reserved, not built (OQ).
- **Reranker fine-tuning / domain training.**
- **Embedding-model or chunking changes** — orthogonal; reranking consumes the existing pool.
- **MCP `document_search` reranking** *if* deferred (OQ) — would be a fast-follow, same seam.

## Test Plan
- **Unit (rag-client):** with a stub reranker returning fixed scores, a known candidate pool is
  reordered as expected; `RAG_RERANK_ENABLED=false` bypasses (identical to current output); a
  reranker that raises ⇒ fallback to RRF order + logged warning; `RERANK_INPUT_K` truncates the
  scored set; over-long passage truncated before scoring. Provider-agnostic fixtures (no live model).
- **Provider unit:** the local reranker scores `(query, [passages])` and returns one score per
  passage in order; the cloud adapter (mocked HTTP) maps its response to the same `list[float]`.
- **Integration (the motivating case):** ingest `CED3.1_Maintenance_Guideline`; a query where RRF
  ranks the answer child at ~rank 4 returns, **after** rerank, that child's parent as `FINAL_K[0]`.
  Regression: a clean single-fact query unaffected; flag-off path matches pre-feature output.
- **Both paths:** if MCP reranking is in scope, `document_search` returns the same reranked
  parent-collapsed order as `retrieve()`.
- **Latency/smoke:** measure rerank time for `candidate_k≈40` on the CPU tier on the running stack;
  record it in the spec and pick the default-on tier from the number.

## Open Questions
- [x] **Provider direction — decided (2026-06-28):** a config-switchable `providers/reranker` seam,
      **default `local` = FlashRank/ONNX (standalone, off the Ollama runtime)**, with `ollama`
      (LLM-as-reranker), `cohere`/`jina` (cloud), and `none` selectable via `RAG_RERANK_PROVIDER`.
      Flexibility-first per the user. *Still open:* which FlashRank ONNX model
      (`ms-marco-MiniLM-L-12-v2` vs. a larger variant) — pick by image-size vs. quality on the CED
      corpus; **bge-reranker-v2-m3** (needs torch / a dedicated container) remains a future quality
      provider if MiniLM under-performs.
- [ ] **In-process vs. dedicated container** for the local reranker. In-process is simplest; a small
      reranker container (mirroring the `ollama` service) keeps the rag-client image lean and lets the
      MCP server share one reranker. Lean toward a container if the model needs torch.
- [ ] **Rerank children vs. parents (vs. two-stage).** Default: children. Evaluate whether holistic
      "give me everything about X" queries want a second pass that reranks the *collapsed parents*.
- [ ] **Default-on tier.** On by default everywhere, or GPU-on / CPU-flagged, pending the measured
      latency on the CPU tier.
- [x] **MCP `document_search` — DONE (2026-06-28): mirrored.** The MCP server got a parallel reranker
      (`ai-mcp-server-v1/reranker.py` + `flashrank` dep + `RAG_RERANK_*` config + tests), wired into
      `document_search` and propagating `rerank_score`. Single tool (config-gated), **not** a second
      with/without-reranker tool — more tools worsen agentic tool-selection and rerank-vs-not is an
      operator decision, not the LLM's. Both paths now agree.
