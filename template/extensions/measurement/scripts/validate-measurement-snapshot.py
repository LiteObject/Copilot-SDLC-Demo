#!/usr/bin/env python3
"""Validate a Phase 7 aggregate measurement snapshot."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import sys
from pathlib import Path

try:
    import measurement
except ImportError:  # pragma: no cover - preserves direct use of the legacy validator
    measurement = None


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot-path", required=True)
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--retention-days", required=True, type=int)
    parser.add_argument("--validation-evidence-path", required=True)
    parser.add_argument("--metric", action="append", default=[])
    parser.add_argument("--config-path")
    parser.add_argument("--catalog-path")
    parser.add_argument("--model")
    return parser.parse_args()


def is_number(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def safe_relative_path(value: object) -> bool:
    if not isinstance(value, str) or not value or os.path.isabs(value):
        return False
    normalized = value.replace("\\", "/")
    return (
        normalized != ".."
        and not normalized.startswith("../")
        and "/../" not in normalized
    )


def add_error(errors: list[str], message: str) -> None:
    errors.append(message)


def validate(args: argparse.Namespace) -> list[str]:
    errors: list[str] = []
    repo_root = Path(args.repo_root).resolve()
    snapshot_path = Path(args.snapshot_path)
    if not snapshot_path.is_file():
        return [f"Snapshot file does not exist: {args.snapshot_path}"]

    try:
        document = json.loads(snapshot_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"Snapshot is not valid JSON: {exc}"]

    if not isinstance(document, dict):
        return ["Snapshot root must be a JSON object."]
    if document.get("schema") != 1:
        add_error(errors, "Snapshot schema must be 1.")
    if document.get("kind") != "sdlc-measurement-snapshot":
        add_error(errors, "Snapshot kind must be 'sdlc-measurement-snapshot'.")
    if document.get("owner") != args.owner:
        add_error(errors, f"Snapshot owner must match configured owner '{args.owner}'.")

    expected_model = args.model
    catalog: dict[str, dict] = {}
    if args.config_path and measurement is not None:
        config = measurement.read_measurement_config(Path(args.config_path))
        expected_model = expected_model or str(config.get("model", ""))
        if not args.metric:
            args.metric = measurement.configured_metric_ids(config)
        catalog_path = args.catalog_path or config.get("catalog_path")
        if catalog_path:
            candidate = Path(args.repo_root) / str(catalog_path)
            try:
                loaded_catalog = measurement.load_json(candidate)
                catalog = {
                    item.get("id"): item
                    for item in loaded_catalog.get("metrics", [])
                    if isinstance(item, dict) and item.get("id")
                }
            except (OSError, json.JSONDecodeError) as exc:
                add_error(errors, f"Measurement catalog could not be loaded: {exc}")
    if expected_model:
        if document.get("model") != expected_model:
            add_error(errors, f"Snapshot model must match '{expected_model}'.")
        if document.get("model_version") != expected_model:
            add_error(errors, f"Snapshot model_version must match '{expected_model}'.")
        cohort = document.get("cohort")
        if (
            not isinstance(cohort, dict)
            or not isinstance(cohort.get("name"), str)
            or not cohort["name"].strip()
            or not isinstance(cohort.get("field"), str)
            or not cohort["field"].strip()
        ):
            add_error(errors, "Snapshot cohort must contain a name and field.")
        completeness = document.get("completeness")
        if not isinstance(completeness, dict):
            add_error(errors, "Snapshot completeness must be an object.")
        else:
            score = completeness.get("score")
            if not is_number(score) or not 0 <= score <= 1:
                add_error(
                    errors, "Snapshot completeness.score must be between 0 and 1."
                )
            if not isinstance(completeness.get("missing_event_types"), list):
                add_error(
                    errors,
                    "Snapshot completeness.missing_event_types must be an array.",
                )
        if document.get("privacy_review") != "APPROVED":
            add_error(errors, "Snapshot privacy_review must be APPROVED.")

    period = document.get("period")
    if not isinstance(period, dict):
        add_error(errors, "Snapshot period must contain start and end dates.")
    else:
        dates: list[dt.date] = []
        for name in ("start", "end"):
            value = period.get(name)
            try:
                dates.append(dt.date.fromisoformat(value))
            except (TypeError, ValueError):
                add_error(errors, f"Snapshot period.{name} must be an ISO date.")
        if len(dates) == 2 and dates[0] > dates[1]:
            add_error(errors, "Snapshot period.start must not be after period.end.")

    metrics = document.get("metrics")
    if not isinstance(metrics, list):
        add_error(errors, "Snapshot metrics must be an array.")
        metrics = []
    expected = set(args.metric)
    seen: set[str] = set()
    for index, metric in enumerate(metrics):
        if not isinstance(metric, dict):
            add_error(errors, f"Metric at index {index} must be an object.")
            continue
        metric_id = metric.get("id")
        if not isinstance(metric_id, str) or not metric_id:
            add_error(errors, f"Metric at index {index} must have a non-empty id.")
            continue
        if metric_id in seen:
            add_error(errors, f"Metric '{metric_id}' occurs more than once.")
        seen.add(metric_id)
        if metric_id not in expected:
            add_error(errors, f"Metric '{metric_id}' is not configured.")
        if (
            not isinstance(metric.get("definition"), str)
            or not metric["definition"].strip()
        ):
            add_error(errors, f"Metric '{metric_id}' must have a definition.")
        if not is_number(metric.get("value")):
            add_error(errors, f"Metric '{metric_id}' value must be numeric.")
        if not is_number(metric.get("baseline_value")):
            add_error(errors, f"Metric '{metric_id}' baseline_value must be numeric.")
        if not isinstance(metric.get("unit"), str) or not metric["unit"].strip():
            add_error(errors, f"Metric '{metric_id}' must have a unit.")
        catalog_metric = catalog.get(metric_id)
        if catalog_metric:
            if metric.get("unit") != catalog_metric.get("unit"):
                add_error(errors, f"Metric '{metric_id}' unit must match the catalog.")
            if metric.get("formula") != catalog_metric.get("formula"):
                add_error(
                    errors, f"Metric '{metric_id}' formula must match the catalog."
                )
            if metric.get("owner") != catalog_metric.get("owner"):
                add_error(
                    errors, f"Metric '{metric_id}' owner must match the catalog owner."
                )
            if not is_number(metric.get("numerator")):
                add_error(
                    errors, f"Metric '{metric_id}' numerator must be numeric evidence."
                )
            if (
                not is_number(metric.get("denominator"))
                or metric.get("denominator") <= 0
            ):
                add_error(
                    errors,
                    f"Metric '{metric_id}' denominator must be positive numeric evidence.",
                )
            source_ids = metric.get("source_ids")
            if (
                not isinstance(source_ids, dict)
                or not isinstance(source_ids.get("event_ids"), list)
                or any(
                    not isinstance(item, str) or not item
                    for item in source_ids["event_ids"]
                )
            ):
                add_error(errors, f"Metric '{metric_id}' must retain source event IDs.")
            required_source_id_fields = {
                "lead_time": ("deployment_ids", "change_ids"),
                "recovery_time": ("incident_ids",),
                "change_failure_rate": ("deployment_ids",),
                "rollback_rate": ("deployment_ids",),
            }.get(metric_id, ())
            for source_id_field in required_source_id_fields:
                values = (
                    source_ids.get(source_id_field)
                    if isinstance(source_ids, dict)
                    else None
                )
                if (
                    not isinstance(values, list)
                    or not values
                    or any(not isinstance(item, str) or not item for item in values)
                ):
                    add_error(
                        errors,
                        f"Metric '{metric_id}' must retain {source_id_field} for its formula joins.",
                    )
        if metric.get("owner") != args.owner:
            add_error(
                errors, f"Metric '{metric_id}' owner must match the configured owner."
            )
        if not isinstance(metric.get("source"), str) or not metric["source"].strip():
            add_error(errors, f"Metric '{metric_id}' must have a source.")
        if metric.get("retention_days") != args.retention_days:
            add_error(
                errors,
                f"Metric '{metric_id}' retention_days must equal {args.retention_days}.",
            )
        if metric.get("privacy_review") != "APPROVED":
            add_error(errors, f"Metric '{metric_id}' privacy_review must be APPROVED.")

    for metric_id in sorted(expected - seen):
        add_error(
            errors, f"Configured metric '{metric_id}' is missing from the snapshot."
        )

    improvements = document.get("improvements")
    if not isinstance(improvements, list):
        add_error(errors, "Snapshot improvements must be an array.")
        improvements = []
    accepted_count = 0
    for index, improvement in enumerate(improvements):
        if not isinstance(improvement, dict):
            add_error(errors, f"Improvement at index {index} must be an object.")
            continue
        if not isinstance(improvement.get("id"), str) or not improvement["id"].strip():
            add_error(errors, f"Improvement at index {index} must have an id.")
        accepted = improvement.get("accepted")
        if not isinstance(accepted, bool):
            add_error(errors, f"Improvement at index {index} accepted must be boolean.")
            continue
        if accepted:
            accepted_count += 1
            for field in ("observed_effect", "regression", "evidence"):
                if (
                    not isinstance(improvement.get(field), str)
                    or not improvement[field].strip()
                ):
                    add_error(
                        errors,
                        f"Accepted improvement at index {index} must have {field}.",
                    )
            evidence = improvement.get("evidence")
            if safe_relative_path(evidence) and not (repo_root / evidence).is_file():
                add_error(
                    errors, f"Accepted improvement evidence does not exist: {evidence}"
                )
            elif not safe_relative_path(evidence):
                add_error(
                    errors,
                    f"Accepted improvement evidence must be a safe relative path: {evidence}",
                )

    review = document.get("review")
    if not isinstance(review, dict):
        add_error(errors, "Snapshot review must be an object.")
    else:
        if review.get("status") != "APPROVED":
            add_error(errors, "Snapshot review.status must be APPROVED.")
        if review.get("completed_improvements") != accepted_count:
            add_error(
                errors,
                "review.completed_improvements must equal accepted improvements.",
            )
        if review.get("regressions_reviewed") is not True:
            add_error(errors, "review.regressions_reviewed must be true.")
        roadmap = review.get("next_prioritized_roadmap")
        if (
            not isinstance(roadmap, list)
            or not roadmap
            or any(not isinstance(item, str) or not item.strip() for item in roadmap)
        ):
            add_error(
                errors,
                "review.next_prioritized_roadmap must contain at least one item.",
            )

    return errors


def main() -> int:
    args = parse_args()
    errors = validate(args)
    evidence_path = Path(args.validation_evidence_path)
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    result = "PASS" if not errors else "FAIL"
    record = {
        "schema": 1,
        "kind": "sdlc-measurement-snapshot-validation",
        "command": "validate-measurement-snapshot.py",
        "snapshot_path": args.snapshot_path,
        "checked_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "expected_metric_count": len(set(args.metric)),
        "exit_code": 0 if not errors else 1,
        "result": result,
        "errors": errors,
    }
    evidence_path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    for error in errors:
        print(f"[FAIL] {error}")
    if errors:
        return 1
    print("[PASS] Measurement snapshot is valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
