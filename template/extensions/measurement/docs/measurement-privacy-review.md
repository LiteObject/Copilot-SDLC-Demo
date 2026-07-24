# Measurement Privacy Review

## Data Minimization

Collect only aggregate delivery, quality, safety, and user-impact measures
needed for the stated improvement question. Do not record prompts, model
inputs, free-form feedback, secrets, credentials, or unnecessary personal data.
Event records may retain repository, feature, change, deployment, incident, and
metric identifiers only as join keys. Aggregated reports link to the retained
event file without copying raw event payloads.

## Data Classification

| Data item | Sensitive or personal data possible | Aggregation or redaction | Source | Retention | Access |
|---|---|---|---|---|---|
| Delivery outcomes | No / explain | | | | |
| Review and rework counts | No / explain | | | | |
| User impact or harm counts | Possible / explain | | | | |
| AI quality and safety measures | Possible / explain | | | | |

## Review Decision

Privacy reviewer: 

Review date: 

Review outcome: `NOT_REVIEWED`

Access controls, deletion process, retention exceptions, and incident handling:
