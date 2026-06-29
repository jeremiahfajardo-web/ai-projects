---
description: Scaffold a new feature spec from the workspace's canonical template. Use when starting any new feature, when the user says "create a spec", "new feature", "draft a feature spec", or before writing implementation code for a new ticket.
---

# Feature Spec Skill

Every non-trivial feature in this workspace starts with a spec, authored
**before** implementation. This workspace already ships the canonical template at
[docs/feature-spec-template.md](docs/feature-spec-template.md) — use that file as
the source, do **not** invent a different structure here.

## Procedure

1. Confirm the feature name with the user if not obvious (kebab-case, no extension).
2. Decide where it lives:
   - **Repo-specific** feature → `<that-repo>/docs/features/<name>.md`
     (e.g. `ai-rag-llm-client-v1/docs/features/`, `ai-mcp-server-v1/docs/features/`).
   - **Cross-repo / umbrella** work → `c:/projects/ai-projects/docs/features/<name>.md`.
3. Copy everything below the `---` divider in
   [docs/feature-spec-template.md](docs/feature-spec-template.md) into the new
   file and fill in everything you can from the conversation. Leave `<...>`
   placeholders only where genuinely unknown and ask the user to fill them in.
4. Stop after the spec is drafted — do not start implementation until the user
   confirms. For any spec spanning backend **and** frontend, remember the
   BE-before-FE hard gate (build + fully test the backend slice first).

## What the template enforces (don't drop these)

- **`## Status`** line `[ ] Spec  [ ] In Progress  [ ] Testing  [ ] Done` —
  advanced in the same PR that ships each stage, monotonically. The
  `docs-stale-check` CI lints this format.
- **Identity & Uniqueness** — every lookup/navigation resolves a row by `id`,
  never by a display string (`filename`/`name`); state the uniqueness scope
  (per `user_id`, not global).
- **Security Checklist** — OWASP Top 10 + LLM Top 10 items, each ticked or marked
  N/A with a one-line reason.
- **Manual smoke checklist** — a flat `- [ ]` list of user-facing actions →
  expected outcomes, run pre-PR. Required; deferred items stay listed with a
  `(skipped — reason)` note.

> Before flipping `[x] Done`, re-read the whole spec against the built code and
> account for every Acceptance Criterion and Open Question (checked, or left
> unchecked with an inline why + follow-up pointer). A recorded smoke-test result
> is part of Definition of Done.
