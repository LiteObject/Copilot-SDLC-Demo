# Measurement Plan

Use this plan to improve delivery outcomes, product quality, safety, and user
impact. Do not use agent activity, prompt count, or code volume as a proxy for
successful delivery.

## Ownership and Cadence

| Item | Value |
|---|---|
| Measurement owner | |
| Review cadence | quarterly |
| Data retention | |
| Privacy reviewer | |
| Exception approver | |

## Model and Cohort

Measurement model: `dora-ai-v1`

Measurement cohort: `all-services` unless the project declares a narrower
service or repository cohort in its configuration.

The JSON catalog and event schema are versioned with the configuration. A
snapshot from another model version cannot be compared or published.

## Outcome Measures

Outcome measures describe whether the process or product achieved its intended
result. Record a baseline before a major process change and compare the next
review period with the same definition and source.

## Leading Indicators

Leading indicators show whether the controls that should produce the outcome
are being applied. They may include complete evidence, validation pass rate,
scope drift, review acceptance, and policy-violation counts.

## Collection Rules

Record aggregate values, the measurement period, a source, an owner, a
definition, a retention rule, and a privacy review decision. Exclude prompts,
free-form user content, secrets, credentials, and unnecessary personal or
sensitive data. Document any sampling, denominator, missing-value, or
exclusion rule. The configured `time_measurement_method` must name how
time-saved-or-added observations were collected; the method is retained with
each time-measurement event.

The `measurement_snapshot` task must write the configured snapshot path as a
JSON document with schema `1` and kind `sdlc-measurement-snapshot`. It must
include the model version, cohort, measurement period, completeness summary,
owner, privacy review, one numeric value and baseline value for each configured
metric, the catalog formula, numeric numerator and denominator, source IDs,
metric definition, source, retention days, and privacy review status. It must
also include an approved review with regression review and any accepted
improvement's observed effect and evidence path.

The report generator reads the configured JSONL events, emits period aggregates
and cohort series, calculates trend deltas against the snapshot baseline, and
records confidence and completeness indicators with links to retained evidence.

Set `measurement.require_completion_gate: true` only when the project wants
measurement evidence required before the SDLC workflow reaches `DONE`. The
normal quarterly cadence does not block every feature transition.

For AI-enabled products, record task quality, safety rate, abstention or
escalation rate, user-reported harms, cost, latency, drift, and incident
recurrence. For conventional products, mark those metrics not applicable and
explain the decision in the privacy review.

## Improvement Acceptance

Every process change needs an observed effect, a comparison with the baseline,
an owner, retained evidence, and a regression review before it is accepted.