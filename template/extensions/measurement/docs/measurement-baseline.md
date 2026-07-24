# Measurement Baseline

Capture this baseline before a major process change. Keep definitions,
denominators, sources, owners, retention, and privacy review decisions stable
enough to make later comparisons meaningful.

| Metric ID | Definition | Owner | Source | Baseline | Retention | Privacy review |
|---|---|---|---|---|---|---|
| `lead_time` | Time from first commit included in a successful production deployment to completion | | | | | |
| `deployment_frequency` | Successful production deployments per period | | | | | |
| `change_failure_rate` | Deployments causing rollback, incident, or remediation | | | | | |
| `recovery_time` | Time from service impact detection to restored service, less paused time | | | | | |
| `escaped_defects` | Defects found after the validation boundary | | | | | |
| `security_findings` | Security findings by severity and disposition | | | | | |
| `review_cycle_count` | Reviewer change cycles per completed change | | | | | |
| `flaky_test_rate` | Test runs failing from nondeterministic behavior | | | | | |
| `rollback_rate` | Releases requiring rollback divided by releases | | | | | |
| `slo_attainment` | Declared SLO attainment for the reporting period | | | | | |

The baseline must use the same model version, cohort, formula, units, event
joins, and missing-data rules as later snapshots. A baseline without a
denominator is not publishable.

Baseline owner: 

Baseline period: 

Measurement limitations and missing data: 