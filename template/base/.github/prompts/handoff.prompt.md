---
description: "Generate a short, copyable prompt orienting a fresh agent on the current feature. Points to the plan, branch, and next action without dumping data."
name: "Handoff"
agent: "sdlc-supervisor"
argument-hint: "[--phase <current-phase>] [--for <agent-name>]"
---
Generate a short agent orientation prompt for the current feature.

1. Read the current state, goal, and next action from [docs/spec.md](../../docs/spec.md).
2. Read the relevant agent definition from `.github/agents/`.
3. Produce a **3–6 sentence prompt** covering:
   - **What to do** — the task for the target agent in one sentence.
   - **Where the plan is** — reference `docs/spec.md` and the relevant sections.
   - **Where to start reading** — which instruction files and agent definitions apply.
   - **Branch / workspace context** — any relevant path or state info.
   - **One-line scope reminder** — what NOT to touch.
4. The receiving agent reads the files itself — this is a pointer, not a data dump.

Context: ${input:phase} ${input:agent}
