# Measurement Metrics Catalog

Each metric has a stable ID, a structured formula, a numerator, a denominator,
an owner, an event source, a cohort, a reporting window, a missing-data rule,
a retention period, a unit, and a privacy classification. The authoritative
machine-readable catalog is `docs/measurement-catalog.json` and is versioned
by `measurement.model` (the template uses `dora-ai-v1`). This Markdown file
explains the intent; validators use the JSON catalog.

Record aggregate values and the period; do not retain prompts, source code,
personal data, model inputs, credentials, or unnecessary sensitive content.

## DORA Measures

`lead_time`, `deployment_frequency`, `change_failure_rate`, and
`recovery_time` use the DORA definitions. The catalog makes the
deployment, change, and incident joins explicit and declares compatible units.
`escaped_defects`, `security_findings`, `flaky_test_rate`, `rollback_rate`,
and `slo_attainment` supplement delivery reliability and quality.

## Delivery and AI-Assisted Development

| Metric ID | Definition | Owner | Source | Retention | Privacy review |
|---|---|---|---|---|---|
| `complete_evidence_rate` | Changes with all required evidence divided by changes | | | | |
| `agent_suggested_defect_rate` | Accepted defects first suggested by an agent divided by changes | | | | |
| `human_rework` | Human rework records divided by changes | | | | |
| `review_acceptance_rate` | Reviews approved without another change cycle | | | | |
| `scope_drift_rate` | Changes outside the approved file plan divided by changes | | | | |
| `validation_pass_rate` | Required validation runs that pass on the first attempt | | | | |
| `model_tool_policy_violations` | Confirmed policy violations divided by changes | | | | |
| `review_cycle_count` | Review cycles divided by reviews | | | | |
| `time_saved_or_added` | Declared seconds saved or added divided by changes | | | | |

## AI Product Measures

Mark these metrics not applicable when the product has no AI capability and
record that decision in the privacy review.

| Metric ID | Definition | Owner | Source | Retention | Privacy review |
|---|---|---|---|---|---|
| `task_quality` | Successful product tasks against the accepted quality measure | | | | |
| `safety_rate` | Safe outcomes divided by evaluated AI interactions | | | | |
| `abstention_escalation_rate` | Appropriate abstentions or human escalations divided by opportunities | | | | |
| `user_reported_harms` | Aggregated reports of harm or material user impact | | | | |
| `cost` | Cost per period or completed task | | | | |
| `latency` | Response latency for the defined percentile or budget | | | | |
| `drift` | Change in data, quality, or safety distribution from baseline | | | | |
| `incident_recurrence` | Repeat incidents with the same root cause | | | | |

## Roadmap Coverage

Each roadmap phase has at least one outcome measure and one leading indicator.

| Metric ID | Type | Phase | Definition | Owner | Source | Retention | Privacy review |
|---|---|---|---|---|---|---|---|
| `phase0_outcome` | outcome | Phase 0 | Workflow integrity outcome | | | | |
| `phase0_leading_indicator` | leading indicator | Phase 0 | Workflow integrity control applied | | | | |
| `phase1_outcome` | outcome | Phase 1 | Reproducible validation outcome | | | | |
| `phase1_leading_indicator` | leading indicator | Phase 1 | Configured validation control applied | | | | |
| `phase2_outcome` | outcome | Phase 2 | Quality and security outcome | | | | |
| `phase2_leading_indicator` | leading indicator | Phase 2 | Test and security coverage control applied | | | | |
| `phase3_outcome` | outcome | Phase 3 | Release and supply-chain outcome | | | | |
| `phase3_leading_indicator` | leading indicator | Phase 3 | Artifact and release evidence control applied | | | | |
| `phase4_outcome` | outcome | Phase 4 | Operational readiness outcome | | | | |
| `phase4_leading_indicator` | leading indicator | Phase 4 | Observability and incident control applied | | | | |
| `phase5_outcome` | outcome | Phase 5 | AI-assisted governance outcome | | | | |
| `phase5_leading_indicator` | leading indicator | Phase 5 | Policy and audit control applied | | | | |
| `phase6_outcome` | outcome | Phase 6 | AI lifecycle outcome | | | | |
| `phase6_leading_indicator` | leading indicator | Phase 6 | Evaluation and monitoring control applied | | | | |
| `phase7_outcome` | outcome | Phase 7 | Measurement and continuous-improvement outcome | | | | |
| `phase7_leading_indicator` | leading indicator | Phase 7 | Measurement ownership, privacy, and review control applied | | | | |