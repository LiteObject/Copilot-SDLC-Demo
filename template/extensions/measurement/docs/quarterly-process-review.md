# Quarterly Process Review

## Period

Review period: 

Measurement owner: 

Review cadence: quarterly

## Results

Summarize outcome measures, leading indicators, trends, missing data, and
regressions against the baseline. Include AI product quality, safety,
abstention or escalation, user-reported harms, cost, latency, drift, and
incident recurrence when applicable.

## Completed Improvements

List accepted changes to prompts, guardrails, test suites, instructions, tools,
or requirements and link the observed-effect evidence for each one.

The machine-readable ledger is `docs/measurement-experiments.json`. A tracked
experiment records an ID, hypothesis, intervention, expected measure, owner,
observed effect, regression check, retained evidence, and decision. A
deteriorating metric must have a proposed, continuing, accepted, or rejected
experiment before the review can pass.

An `ACCEPTED` experiment must include an observed effect and a passing
`regression_check`; a process change is never declared effective from intent,
activity, prompt count, or code volume alone.

## Unresolved Risks

Record residual risks, owners, due dates, and any time-bound exceptions.

## Exception Trends

Summarize exception counts, repeated exceptions, approval status, and expiry
dates.

## Next Prioritized Roadmap

1. 
2. 
3. 

## Regression Review

State whether any improvement regressed delivery time, quality, safety, user
impact, cost, latency, or operational stability. Review outcome: `NOT_REVIEWED`.