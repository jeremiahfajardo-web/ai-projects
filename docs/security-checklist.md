# Security Checklist — ai-projects

This is the **workspace-wide** security review standard for every repo in the
`ai-projects` stack (`ai-infrastructure-v1`, `ai-database-v1`, `ai-mcp-server-v1`,
`ai-rag-llm-client-v1`, and the image-based `ai-n8n-v1` service). It is the canonical,
single-sourced list — the per-feature `## Security Review` section of
[feature-spec-template.md](feature-spec-template.md) links here and carries only the
*this-feature* ticks. Keep the wording here; don't fork it into each spec.

It pairs with [coding-style.md](coding-style.md) (several items below are already
enforced as coding-style rules — those are cross-linked rather than restated).

## How to use this per feature

In each `docs/features/<name>.md`, copy the **checkbox skeleton** at the bottom of this
file into the spec's `## Security Review` section and, for every item, do one of:

- **`[x]`** — addressed by this feature; one line on *how*.
- **`[ ] … N/A — <why>`** — does not apply to this feature's surface (e.g. "no new
  outbound request", "no LLM in this path"). Silence is not allowed — an item is either
  ticked or explicitly marked N/A with a reason.
- **`[ ] … deferred — <seam>`** — a known gap left open on purpose, naming the seam that
  keeps the fix additive (per *defer features, build seams*). Link the follow-up if one
  exists.

This list is part of the Definition of Done: a spec cannot flip `[x] Done` with a
security item silently unaddressed (see CLAUDE.md → SDLC Phase Instructions).

## Stack security posture (read first)

A few facts change how the rows below apply to *this* stack — internalise them so reviews
don't mis-tag items:

- **No authentication yet.** Identity is a schema-only `user_id` behind the
  `get_current_user()` seam (returns the default local user). The `X-User-ID` header
  contract between the RAG client and the MCP server is an **ownership/scoping** signal,
  **not** authentication — it is unauthenticated and trusted only because the stack is
  single-tenant and local. Treat real auth (A07) as *deferred — seam exists*, not done.
- **Local-first, no cloud keys required.** The Anthropic cloud-LLM adapter is an optional
  provider behind the `providers/` seam; its API key lives in `.env` only.
- **Real outbound surface exists.** The MCP `web` tool and n8n make outbound HTTP
  requests, so **A10 SSRF is in scope**, not N/A as it would be for a closed app.
- **LLM output reaches the UI and drives tools.** Model output is rendered in the Vue
  client and is also parsed into MCP tool calls — so output-handling (LLM05) and excessive
  agency (LLM06) are live concerns, not theoretical.

---

## OWASP Top 10 (2021)

- **A01 Broken Access Control** — Every user-owned read filters by `user_id` and every
  write stamps it, sourced from the single `get_current_user()` seam; soft-deleted rows
  (`deleted_at`) are excluded from reads. Cross-user recall (memory, documents, vectors)
  must never be possible. *Deferred:* an `auth_required` dependency on `/api/*` once real
  auth lands — the seam is already in place.
- **A02 Cryptographic Failures** — No secrets, keys, or credentials in source — `.env`
  only (coding-style General Principles). Cloud provider API keys live in `.env` and are
  never logged. TLS termination is deferred for the local stack; revisit before any
  non-localhost exposure.
- **A03 Injection** — ORM / parameterized queries throughout; **raw SQL only for pgvector
  similarity** and even then fully parameterized (coding-style SQL rules). LLM-driven
  injection is covered separately under **LLM01**.
- **A04 Insecure Design** — *Defer features, build seams*; least-privilege DB users
  (`ai-database-v1`); responses expose the minimum fields needed (no PII/secret
  over-fetch).
- **A05 Security Misconfiguration** — Required env vars fail fast at startup (the
  config-self-check boot guard); `.env.example` documents **every** new var with no
  insecure default; CORS is scoped intentionally; debug/verbose modes off in any
  non-local deployment.
- **A06 Vulnerable & Outdated Components** — Python deps pinned in `requirements*.txt`;
  Docker base images and `n8nio/n8n` tag reviewed periodically; flag any newly added
  dependency in the spec.
- **A07 Identification & Authentication Failures** — *Deferred — seam exists.* No auth in
  v1; the `X-User-ID` contract is ownership scoping, not authentication. When auth lands,
  this row covers credential storage, session handling, and enumeration resistance.
- **A08 Software & Data Integrity Failures** — Deps pinned; container images from known
  tags. The **Plugin SDK auto-discovers MCP tools** — only load tools from trusted source
  dirs; treat tool discovery as a trust boundary.
- **A09 Security Logging & Monitoring Failures** — Structured logs at the FastAPI and tool
  boundaries; **never log secrets, API keys, full prompts containing user data, or raw
  embeddings**. Errors surface as clean HTTP statuses, not stack traces, to clients.
- **A10 SSRF** — **In scope.** The MCP `web` tool and n8n make outbound requests; validate
  / allowlist target URLs and reject internal-network / metadata-endpoint destinations.
  Mark N/A only for a feature that adds no new outbound request path.

## AI / LLM-Specific (OWASP LLM Top 10, 2025)

- **LLM01 Prompt Injection** — RAG-retrieved chunks and tool outputs flow into the prompt,
  so **indirect prompt injection** is the primary risk. Keep retrieved/tool content
  clearly delimited from instructions; don't let it redirect tool use or exfiltrate
  context.
- **LLM02 Sensitive Information Disclosure** — Memory/document/vector recall is scoped by
  `user_id`; verify a feature can't leak another user's content or the system prompt
  beyond what's intentionally exposed (see LLM07).
- **LLM03 Supply Chain** — Models are pulled by `ollama-init`; provider adapters and
  Plugin-SDK tools are code — pin and review their sources.
- **LLM04 Data & Model Poisoning** — Ingested documents and written memories become
  retrievable context; consider who can ingest/write and whether poisoned content can
  steer later answers.
- **LLM05 Improper Output Handling** — LLM output is rendered in the Vue UI (escape it —
  no `v-html` on model text → XSS) **and** parsed into tool calls (the server `ToolRequest`
  base + client `_sanitize_tool_args` already harden arg parsing; keep new tools on that
  path).
- **LLM06 Excessive Agency** — The model can invoke MCP tools (`web`, `vector`, `memory`,
  `rag`); user-selectable dynamic tools widen this. Scope each tool to the least capability
  needed; a new tool that mutates state or reaches the network must justify its blast
  radius here.
- **LLM07 System Prompt Leakage** — The system prompt is shown in the UI **by design**
  (the response panel) — note this is intentional and ensure it contains no secrets, so
  the exposure is harmless.
- **LLM08 Vector & Embedding Weaknesses** — Embedding provenance (`embedding_model` +
  `embedding_dimension`) and the alignment check guard model/dim mismatch (`409`);
  retrieval is `user_id`-scoped so embeddings can't cross tenants.
- **LLM09 Misinformation** — RAG answers stay grounded in retrieved context with
  citations; flag any path where the model answers ungrounded.
- **LLM10 Unbounded Consumption** — Bound token usage / tool-call loops; the cloud provider
  adapter has real cost — consider per-request caps and that a tool loop can't run away.

---

## Checkbox skeleton (copy into each spec's `## Security Review`)

```markdown
## Security Review
Reviewed against [docs/security-checklist.md](../security-checklist.md). Each item is
ticked (with how), or `N/A — <why>`, or `deferred — <seam>`.

### OWASP Top 10 (2021)
- [ ] **A01 Broken Access Control** —
- [ ] **A02 Cryptographic Failures** —
- [ ] **A03 Injection** —
- [ ] **A04 Insecure Design** —
- [ ] **A05 Security Misconfiguration** —
- [ ] **A06 Vulnerable & Outdated Components** —
- [ ] **A07 Identification & Authentication Failures** —
- [ ] **A08 Software & Data Integrity Failures** —
- [ ] **A09 Security Logging & Monitoring Failures** —
- [ ] **A10 SSRF** —

### AI / LLM-Specific (OWASP LLM Top 10, 2025)
- [ ] **LLM01 Prompt Injection** —
- [ ] **LLM02 Sensitive Information Disclosure** —
- [ ] **LLM03 Supply Chain** —
- [ ] **LLM04 Data & Model Poisoning** —
- [ ] **LLM05 Improper Output Handling** —
- [ ] **LLM06 Excessive Agency** —
- [ ] **LLM07 System Prompt Leakage** —
- [ ] **LLM08 Vector & Embedding Weaknesses** —
- [ ] **LLM09 Misinformation** —
- [ ] **LLM10 Unbounded Consumption** —
```
