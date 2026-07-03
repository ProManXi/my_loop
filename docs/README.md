# MyLoop Documentation

This is the canonical, in-repository knowledge base for MyLoop. **No external tools
(Notion, Confluence, etc.) are used** — every decision, plan, runbook, and learning
lives here and versions alongside the code it describes.

## Layout

| Folder | What lives here |
|--------|-----------------|
| `architecture/` | How the system actually works — system overview, claim pipeline, spatial model, real-time contract, and the full [frontend↔backend reference](architecture/frontend-backend-reference.md) (every endpoint, SignalR hub, and provider mapping). |
| `product/` | Product & technical [spec](product/spec.md) and the game-design [decision log](product/design-log.md) — what we're building and why. |
| `decisions/` | Architectural Decision Records (ADRs). One file per decision, **append-only** once Accepted. |
| `runbooks/` | Operational procedures — deploys, DB migrations, incident response. |
| `compliance/` | Apple App Store review, privacy manifest mapping, data-deletion guarantees. |
| `learnings/` | Running log of non-obvious discoveries, per phase. |

## How to contribute docs

1. **Made an architectural choice?** Write an ADR (`decisions/`). Copy `decisions/0000-template.md`,
   bump the number, fill it in, set status to `Proposed`, then `Accepted` once agreed.
   **Never edit an Accepted ADR** — supersede it with a new one that links back.
2. **Changed how the system works?** Update the relevant file in `architecture/` in the
   *same PR* as the code change. Docs that drift are worse than no docs.
3. **Discovered something non-obvious?** Add a dated entry to `learnings/<phase>.md`.
4. **Wrote/changed an operational step?** Update the relevant `runbooks/` file.

## Source of truth

Where this documentation and the root `README.md` disagree, **this folder wins** and the
root README should be corrected in the same PR.
