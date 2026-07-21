---
description: Lifecycle controls for products that expose or depend on AI
applyTo: "**/*"
---

# AI Product Lifecycle Rules

Apply these rules only when `.github/sdlc-config.yml` has
`ai_lifecycle.enabled: true`. Conventional software and repositories that use
AI only as a coding aid do not need this extension.

- Do not begin architecture or implementation of an AI feature without an approved impact assessment covering intended and prohibited uses, affected communities, harm scenarios, applicable law and policy, human oversight, contestability, and a named risk owner.
- Keep the versioned AI system inventory current for models, providers, prompts, system instructions, tools, retrieval sources, embeddings, datasets, evaluation datasets, safety filters, fallback behavior, licenses, terms, lineage, retention, and change history.
- Treat material model, prompt, retrieval, tool, data, embedding, or safety-policy changes as release events. Rerun the documented representative and adversarial evaluation and block release when quality or safety thresholds fail.
- Test task quality, reliability, grounding, hallucination, misinformation, privacy, fairness where applicable, robustness, prompt injection, jailbreak resistance, insecure tool invocation, retrieval quality, and refusal or fallback behavior.
- Keep authentication, authorization, least privilege, rate and cost limits, input and output validation, safety filters, PII handling, audit logs, human escalation, kill switches, and safe fallback behavior enforced at runtime.
- Do not place secrets, unnecessary personal data, hidden system instructions, or sensitive user content in evaluation fixtures, logs, model cards, system cards, or incident evidence.
- Record red-team findings, mitigations, residual risk, approval, and retest evidence before high-impact release. Do not silently waive a high-impact finding.
- Monitor quality, safety events, drift, adversarial activity, cost, latency, tool actions, user feedback, and disproportional impact. Exercise detection, containment, rollback, stakeholder communication, and recovery before production release.
- Keep model cards, system cards, known limitations, data-use disclosures, support or appeal mechanisms, rollback plans, and decommissioning plans aligned with the deployed inventory.
