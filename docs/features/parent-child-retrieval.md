# Feature: Parent/child retrieval (structure-aware) + wide candidate net

## Status
[x] Spec  [x] In Progress  [x] Testing  [ ] Done

_Last updated: 2026-06-26 — **Testing passed; pending commit.** Code complete on
`feat/parent-child-retrieval` across ai-rag-llm-client-v1 / ai-mcp-server-v1 /
ai-infrastructure-v1. **Unit tests green in-container** (RAG 82 passed, MCP test_rag 13 passed).
**Live smoke test PASSED on the running stack:** migration 0006 applied; CED fixture ingested
(8 parents incl. a whole "CED REPORTS" section, 33 children); `document_search` for "Provide all
of CED reports available" returns the CED REPORTS parent as the top hit with **all five reports**
— even with the original fragmented PDF still in the DB competing. Done once committed (running
containers are live-patched via docker cp + restart; a `compose up --build` will bake the branch)._

> **Correction vs. draft:** the schema migration lives in the **RAG client's** Alembic
> (`ai-rag-llm-client-v1/backend/migrations/versions/0006_parent_child_chunks.py`), **not**
> `ai-database-v1` — `documents`/`document_chunks` are owned by the RAG client's migrations
> (0001–0005), while `ai-database-v1/init.sql` owns the memory/session/web tables.

## Problem Statement
Hybrid retrieval misses chunks when an answer **spans a chunk boundary** and the continuation
chunk loses its section context. Verified live: the query *"Provide all of CED reports available"*
against [CED3.1_Maintenance_Guideline] returns only the first 3 of 5 reports — the chunk holding
reports 4–5 lost the "CED REPORTS" heading + intro at the split, so it's a weak match for the
holistic query and **never enters the candidate set, at any top-k**. Two root causes confirmed in
code:

1. **No parent context** — chunks are retrieved and returned individually; a fragment stripped of
   its heading can't be matched by a section-level question.
2. **Candidate pool == final k** — hybrid fuses only `top_k` (default 5, client-capped at 10) per
   method ([rag.py:110-116](../ai-rag-llm-client-v1/backend/app/services/rag.py#L110)), so a
   weakly-ranked continuation chunk is dropped before fusion.

Plus a latent sizing bug: chunks are **512 *characters*** (`length_function=len`,
[ingestor.py:83](../ai-rag-llm-client-v1/backend/app/services/ingestor.py#L83)), ~¼ the documented
"512 tokens" — over-fragmenting and amplifying the boundary problem.

This feature: **structure-aware parent/child chunking** (match small children → return the whole
parent section) + a **wide candidate net** (decouple retrieval pool from final result) + a
**token-based sizing** fix. One correct re-ingestion.

## Motivating Case (tunes the defaults)
Doc: `CED3.1_Maintenance_Guideline` (Sprint/Nextel, clear section headings). Query: *"Provide all
of CED reports available."* Expected: all 5 reports (Unassigned BR's, Incorrect BR Type, Missing
Diplexer, Mislabeled Racks, Antenna N/A). Today: first 3 only. The list spans a boundary; the
continuation chunk is a weak holistic match → invisible. **A fixed-size parent could still split
the list**, so parents must follow **section structure**, not byte size.

## Acceptance Criteria
- [ ] **The motivating case passes:** *"Provide all of CED reports available"* returns context
      containing **all five** reports — because a child hit anywhere in the `CED REPORTS` section
      returns that whole section as the parent.
- [ ] **Structure-aware parents:** parent boundaries follow detected document structure (headings/
      sections); a section shorter than the parent cap stays in **one** parent regardless of length.
      Fixed-size splitting is the fallback only for text with no detectable structure.
- [ ] **Children embedded, parents returned:** small children carry the embedding + tsvector and
      are what's searched; on a hit the **parent** text (deduped, ordered) is what's handed to the
      LLM as context.
- [ ] **Wide candidate net:** retrieval pulls a configurable `candidate_k` (default ~40) per method
      into fusion, then collapses to ≤ `final_k` **parents** — decoupled from the old `top_k`.
- [ ] **Token-based sizing:** child/parent sizes are measured in tokens (not characters); defaults
      documented and configurable.
- [ ] **Citations preserved:** a returned parent still resolves to its `document_id` (and which
      child(ren) matched) so the UI's source citation keeps working.
- [ ] **Same embedding model** (`mxbai-embed-large`, 1024) — re-chunk + re-embed only; **not** an
      embedding-model change. Clean re-ingest of any existing docs.
- [ ] **Contextual-chunk seam:** the child row reserves an optional `context` field so the deferred
      "contextual retrieval" enrichment is additive, not a re-migration.

## Affected Repos / Surfaces
- **ai-database-v1**: migration — `parent_chunks` table + `document_chunks.parent_chunk_id` FK
  (children) + index. Embedding stays on children.
- **ai-rag-llm-client-v1**: [ingestor.py](../ai-rag-llm-client-v1/backend/app/services/ingestor.py)
  — structure-aware two-tier split + token length fn; persist parents then children.
  [rag.py](../ai-rag-llm-client-v1/backend/app/services/rag.py) — wide `candidate_k`, child search →
  parent collapse/dedup → return parents; config keys.
- **ai-mcp-server-v1**: [tools/rag.py](../ai-mcp-server-v1/tools/rag.py) `document_search` mirrors
  the same parent-collapse contract (both retrieval paths must agree).
- **ai-infrastructure-v1**: new `.env` defaults (`RAG_CHILD_TOKENS`, `RAG_PARENT_MAX_TOKENS`,
  `RAG_CANDIDATE_K`, `RAG_FINAL_K`).

## Inputs

| Name | Type | Source | Notes |
|---|---|---|---|
| `RAG_CHILD_TOKENS` | int | config | child target size, default ~350 tok |
| `RAG_PARENT_MAX_TOKENS` | int | config | parent cap; a section larger than this splits into multiple parents, default ~1500 tok |
| `RAG_CANDIDATE_K` | int | config | children pulled per method into fusion, default ~40 |
| `RAG_FINAL_K` | int | config | max **parents** returned to the LLM, default ~5 |
| structure hints | derived | extractor | headings/section markers used for parent boundaries (markdown headers for controlled demo docs; heuristic for arbitrary PDFs) |

## Outputs / Response Shape
Returned context items are **parents**, with the matched child(ren) noted for citation/debug:
```json
[
  { "parent_id": "uuid", "doc_id": "uuid", "parent_index": 5,
    "content": "CED REPORTS\nThe following CED Reports... Unassigned BR's... Antenna N/A...",
    "matched_child_ids": ["uuid-childX"], "score": 0.0167, "search_type": "hybrid" }
]
```

## Data Flow
```
ingest:
  extract_text → detect structure (headings) →
    for each section ≤ PARENT_MAX_TOKENS → 1 parent ; larger → split into N parents
    for each parent → split into children (~CHILD_TOKENS, token length fn)
  INSERT parent_chunks (content, parent_index, document_id)
  INSERT document_chunks (content, embedding, search_vector, parent_chunk_id)   # embed children only

retrieve (hybrid):
  embed(query) →
  child semantic top CANDIDATE_K + child keyword top CANDIDATE_K → RRF over the wide pool
  → map ranked children → distinct parent_chunk_id (keep best child rank per parent)
  → load parent_chunks.content, order, take FINAL_K parents
  → return parents (with matched_child_ids for citation)
```

## Schema Impact
Migration (Alembic). Re-ingest required (re-chunk + re-embed; same model/dim).
- **`parent_chunks`** — `id uuid pk`, `document_id fk`, `parent_index int`, `content text`,
  `token_count int`, `section_title text null`. No embedding. Ownership via `documents.user_id`
  JOIN (mirrors `document_chunks` today).
- **`document_chunks`** (children) — add `parent_chunk_id uuid fk → parent_chunks(id)`. Keep
  `embedding VECTOR(1024)` + provenance (`embedding_model`, `embedding_dimension`) + `search_vector`.
  Add optional **`context text null`** (reserved for the deferred contextual-chunk step).
- Index: `document_chunks(parent_chunk_id)`; existing ivfflat + GIN unchanged.
- Provenance unchanged (children still record model/dim). Embedding model unchanged — **not**
  destructive beyond a re-ingest.

## Seams & Forward-Compatibility
- **Reranker (next spec):** drops in between "RRF over wide pool" and "collapse to parents" — the
  wide `candidate_k` is exactly its input. This is the Phase 4 deferred RAG pipeline-step hook
  ([phase4-plugin-sdk-n8n.md](phase4-plugin-sdk-n8n.md) OQ#5).
- **Contextual retrieval (#3, deferred):** the reserved `document_chunks.context` column lets an
  ingestion step prepend an LLM-written situating blurb to each child's embedded text later —
  additive, no migration. Defer for **local-compute cost**, not bias (it adds context, preserves
  original text).
- **Parent granularity is config**, so per-vertical tuning (dense regs vs. handbooks) is a value
  change, consistent with the Core/Pack boundary.

## Edge Cases & Error Handling
- **Section larger than `PARENT_MAX_TOKENS`** (e.g. a long procedure): split into multiple parents;
  enumeration within it can still span parents — documented limit, mitigated by a generous cap.
- **No detectable structure** (flat text / messy PDF): fall back to fixed-size parents +
  children; log that structure detection found nothing.
- **Heading detection from PDF is heuristic** — pdfplumber yields plain text without style; rely on
  caps/known patterns and **prefer markdown for controlled demo docs** (see Open Questions).
- **Child with no parent:** ingestion must guarantee every child has a `parent_chunk_id` (a tiny
  doc → parent == its own single child's text).
- **Parent dedup:** multiple child hits in one section collapse to a single parent (no duplicate
  context); keep the best child rank for ordering.
- **Context budget:** returning whole parents costs more tokens — `FINAL_K` parents must fit the
  model's window; cap parents and (optionally) trim to matched-section.

## Out of Scope for This Feature
- The **reranker** (additive follow-on spec).
- **Contextual-chunk** enrichment (#3) — seam reserved, not built.
- Document-level AI summaries (#2).
- OCR / scanned-image docs (the CED doc's tables are extracted as text; image-only pages are out).
- Changing the embedding model.

## Test Plan
- **Unit (ingest):** a doc with headings produces parents on section boundaries; a section under
  the cap → exactly one parent; children all carry a `parent_chunk_id`; token sizing (not char).
- **Unit (retrieve):** child hits collapse to deduped parents; `candidate_k` widens the pool;
  best-child-rank ordering; `final_k` caps parents.
- **Integration (the motivating case):** ingest `CED3.1_Maintenance_Guideline`, query *"Provide all
  of CED reports available"* → returned context contains **all five** report names. Regression: a
  single-fact query (e.g. "what is the default BR LABEL value?") still returns the right section.
- **Both paths:** RAG-client `retrieve()` and MCP `document_search` return the same parent-collapsed
  shape.

## Open Questions
- [ ] **Heading detection strategy** from extracted PDF text (heuristic caps/numbering vs. a light
      layout parse) — and whether to **author demo docs as Markdown** so the demo path is reliable
      while arbitrary-PDF robustness improves separately.
- [ ] **Default sizes** — validate `CHILD_TOKENS ~350` / `PARENT_MAX_TOKENS ~1500` against the CED
      doc and a home-care handbook before locking.
- [ ] **Return shape to the LLM** — whole parent vs. parent-with-matched-child-highlighted; and
      whether to also keep the raw child for tight factoid queries.
- [ ] **Tokenizer** for the length function (tiktoken vs. the Ollama model's) — approximate is fine,
      pick one and be consistent ingest/retrieve.
```
