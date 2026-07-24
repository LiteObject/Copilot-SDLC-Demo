#!/usr/bin/env python3
"""Canonical validation, aggregation, and review checks for CG-7 metrics."""

from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable

MODEL_PATTERN = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
METRIC_PATTERN = re.compile(r"^[a-z][a-z0-9_]*$")
ALLOWED_FORMULA_OPERATIONS = {"ratio", "average_duration"}
ALLOWED_OPERAND_OPERATIONS = {
    "count",
    "count_distinct",
    "count_true",
    "sum",
    "average",
}
FORBIDDEN_KEY_PARTS = {
    "credential",
    "email",
    "model_input",
    "personal_data",
    "prompt",
    "secret",
    "source_code",
    "user_content",
    "user_input",
}


def strip_comment(value: str) -> str:
    quoted = ""
    escaped = False
    for index, character in enumerate(value):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quoted == '"':
            escaped = True
            continue
        if character in {'"', "'"}:
            if not quoted:
                quoted = character
            elif quoted == character:
                quoted = ""
        elif (
            character == "#"
            and not quoted
            and (index == 0 or value[index - 1].isspace())
        ):
            return value[:index].rstrip()
    return value.rstrip()


def split_inline_list(value: str) -> list[str]:
    inner = value.strip()[1:-1].strip()
    if not inner:
        return []
    items: list[str] = []
    start = 0
    quoted = ""
    escaped = False
    for index, character in enumerate(inner):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quoted == '"':
            escaped = True
            continue
        if character in {'"', "'"}:
            if not quoted:
                quoted = character
            elif quoted == character:
                quoted = ""
        elif character == "," and not quoted:
            items.append(inner[start:index].strip())
            start = index + 1
    items.append(inner[start:].strip())
    return [parse_scalar(item) for item in items if item]


def parse_scalar(value: str) -> str:
    value = strip_comment(value).strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {'"', "'"}:
        if value[0] == '"':
            try:
                return str(json.loads(value))
            except json.JSONDecodeError:
                return value[1:-1].replace('\\"', '"')
        return value[1:-1]
    return value


def read_measurement_config(path: Path) -> dict[str, Any]:
    """Read the deliberately small, inline-list measurement YAML section."""

    content = path.read_text(encoding="utf-8").splitlines()
    in_measurement = False
    values: dict[str, Any] = {}
    for raw_line in content:
        line = raw_line.rstrip("\r")
        if not in_measurement:
            if line.strip() == "measurement:":
                in_measurement = True
            continue
        if line and not line[0].isspace():
            break
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        match = re.match(r"^\s{2}([A-Za-z0-9_]+):\s*(.*)$", line)
        if not match:
            continue
        key, raw_value = match.groups()
        raw_value = raw_value.strip()
        if raw_value.startswith("[") and raw_value.endswith("]"):
            values[key] = split_inline_list(raw_value)
        else:
            values[key] = parse_scalar(raw_value)
    return values


def as_bool(value: Any) -> bool:
    return str(value).lower() == "true"


def safe_relative_path(value: Any) -> bool:
    if not isinstance(value, str) or not value or os.path.isabs(value):
        return False
    normalized = value.replace("\\", "/")
    return (
        normalized not in {".."}
        and not normalized.startswith("../")
        and "/../" not in normalized
    )


def repo_path(repo_root: Path, value: str) -> Path:
    if not safe_relative_path(value):
        raise ValueError(f"Path must be repository-relative: {value}")
    return repo_root / value.replace("/", os.sep)


def load_json(path: Path) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def write_evidence(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )


def contains_forbidden_key(value: Any, location: str = "") -> str | None:
    if isinstance(value, dict):
        for key, child in value.items():
            normalized = str(key).lower()
            if any(part in normalized for part in FORBIDDEN_KEY_PARTS):
                return f"Privacy-sensitive field is not allowed: {location + '.' if location else ''}{key}"
            found = contains_forbidden_key(
                child, f"{location}.{key}" if location else str(key)
            )
            if found:
                return found
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found = contains_forbidden_key(child, f"{location}[{index}]")
            if found:
                return found
    return None


def configured_metric_ids(config: dict[str, Any]) -> list[str]:
    fields = [
        "baseline_metrics",
        "delivery_metrics",
        "phase_outcome_metrics",
        "phase_leading_indicators",
    ]
    if as_bool(config.get("ai_product_metrics_applicable", False)):
        fields.append("ai_product_metrics")
    result: list[str] = []
    for field in fields:
        for metric_id in config.get(field, []):
            if metric_id not in result:
                result.append(str(metric_id))
    return result


def validate_formula(
    formula: Any, metric: dict[str, Any], event_types: set[str]
) -> list[str]:
    errors: list[str] = []
    metric_id = metric.get("id", "<unknown>")
    if not isinstance(formula, dict):
        return [f"Metric '{metric_id}' formula must be a structured object."]
    operation = formula.get("operation")
    if operation not in ALLOWED_FORMULA_OPERATIONS:
        errors.append(
            f"Metric '{metric_id}' formula operation must be ratio or average_duration."
        )
    formula_unit = formula.get("unit")
    if not isinstance(formula_unit, str) or not formula_unit.strip():
        errors.append(f"Metric '{metric_id}' formula must declare an output unit.")
    elif formula_unit != metric.get("unit"):
        errors.append(f"Metric '{metric_id}' formula unit must match metric unit.")
    for name in ("numerator", "denominator"):
        operand = formula.get(name)
        if not isinstance(operand, dict):
            errors.append(
                f"Metric '{metric_id}' formula is missing a structured {name}."
            )
            continue
        operand_operation = operand.get("operation")
        if name == "denominator" and operand_operation == "period_count":
            if not isinstance(operand.get("unit"), str) or not operand["unit"].strip():
                errors.append(f"Metric '{metric_id}' denominator must declare a unit.")
        elif operand_operation not in ALLOWED_OPERAND_OPERATIONS:
            errors.append(
                f"Metric '{metric_id}' {name} operation is missing or unsupported."
            )
        if name == "numerator" and operation == "average_duration":
            if (
                not isinstance(operand.get("event_type"), str)
                or not operand["event_type"]
            ):
                errors.append(
                    f"Metric '{metric_id}' duration numerator must declare an event source."
                )
            if not isinstance(operand.get("start_field"), str) or not isinstance(
                operand.get("end_field"), str
            ):
                errors.append(
                    f"Metric '{metric_id}' duration formula must declare start_field and end_field."
                )
            start_type = operand.get("start_event_type", operand.get("event_type"))
            if start_type not in event_types:
                errors.append(
                    f"Metric '{metric_id}' references unknown start event type '{start_type}'."
                )
        elif operand_operation != "period_count":
            event_type = operand.get("event_type")
            if not isinstance(event_type, str) or not event_type:
                errors.append(
                    f"Metric '{metric_id}' {name} must declare an event source."
                )
            elif event_type not in event_types:
                errors.append(
                    f"Metric '{metric_id}' references unknown event type '{event_type}'."
                )
            field = operand.get("field")
            if operand_operation in {
                "count_distinct",
                "count_true",
                "sum",
                "average",
            } and not isinstance(field, str):
                errors.append(
                    f"Metric '{metric_id}' {name} must declare a field for {operand_operation}."
                )
        filters = operand.get("filters", {})
        if not isinstance(filters, dict):
            errors.append(f"Metric '{metric_id}' {name} filters must be an object.")
        related = operand.get("related_event")
        if related is not None and not isinstance(related, dict):
            errors.append(f"Metric '{metric_id}' related_event must be an object.")
    return errors


def validate_catalog(
    catalog: Any, config: dict[str, Any], event_schema: Any
) -> tuple[list[str], dict[str, dict[str, Any]]]:
    errors: list[str] = []
    metrics_by_id: dict[str, dict[str, Any]] = {}
    if not isinstance(catalog, dict):
        return ["Measurement catalog root must be an object."], metrics_by_id
    if catalog.get("schema") != 1:
        errors.append("Measurement catalog schema must be 1.")
    if catalog.get("kind") != "sdlc-measurement-catalog":
        errors.append("Measurement catalog kind is invalid.")
    model = config.get("model")
    if not isinstance(model, str) or not MODEL_PATTERN.fullmatch(model):
        errors.append("measurement.model must be a versioned lowercase model ID.")
    elif catalog.get("model") != model:
        errors.append("Measurement catalog model must match measurement.model.")
    configured_owner = config.get("owner")
    if not isinstance(configured_owner, str) or not configured_owner.strip():
        errors.append("measurement.owner must be configured.")
    event_types = set()
    if isinstance(event_schema, dict) and isinstance(
        event_schema.get("event_types"), dict
    ):
        event_types = set(event_schema["event_types"])
    metrics = catalog.get("metrics")
    if not isinstance(metrics, list) or not metrics:
        errors.append("Measurement catalog metrics must be a non-empty array.")
        metrics = []
    for index, metric in enumerate(metrics):
        if not isinstance(metric, dict):
            errors.append(f"Catalog metric at index {index} must be an object.")
            continue
        metric_id = metric.get("id")
        if not isinstance(metric_id, str) or not METRIC_PATTERN.fullmatch(metric_id):
            errors.append(
                f"Catalog metric at index {index} must have a stable lowercase ID."
            )
            continue
        if metric_id in metrics_by_id:
            errors.append(f"Catalog metric '{metric_id}' occurs more than once.")
        metrics_by_id[metric_id] = metric
        for field in (
            "name",
            "category",
            "unit",
            "owner",
            "window",
            "missing_data_rule",
            "privacy",
        ):
            if not isinstance(metric.get(field), str) or not metric[field].strip():
                errors.append(f"Metric '{metric_id}' must declare {field}.")
        if (
            not isinstance(metric.get("retention_days"), int)
            or metric["retention_days"] < 1
        ):
            errors.append(
                f"Metric '{metric_id}' retention_days must be a positive integer."
            )
        configured_retention = config.get("retention_days")
        if str(configured_retention).isdigit() and metric.get("retention_days") != int(
            configured_retention
        ):
            errors.append(
                f"Metric '{metric_id}' retention_days must match measurement.retention_days."
            )
        if (
            isinstance(configured_owner, str)
            and configured_owner.strip()
            and metric.get("owner") != configured_owner
        ):
            errors.append(f"Metric '{metric_id}' owner must match measurement.owner.")
        cohort = metric.get("cohort")
        if (
            not isinstance(cohort, dict)
            or not isinstance(cohort.get("field"), str)
            or not cohort["field"].strip()
        ):
            errors.append(f"Metric '{metric_id}' must declare a cohort field.")
        errors.extend(validate_formula(metric.get("formula"), metric, event_types))
        source = metric.get("event_source")
        if not isinstance(source, str) or not source.strip():
            errors.append(f"Metric '{metric_id}' must declare an event_source.")
        if metric_id == "change_failure_rate":
            related = (
                metric.get("formula", {}).get("numerator", {}).get("related_event", {})
            )
            configured_window = config.get("change_failure_window_days")
            if str(configured_window).isdigit() and related.get("window_days") != int(
                configured_window
            ):
                errors.append(
                    "change_failure_rate related-event window must match "
                    "measurement.change_failure_window_days."
                )
    expected = configured_metric_ids(config)
    for metric_id in expected:
        if metric_id not in metrics_by_id:
            errors.append(
                f"Configured metric '{metric_id}' is missing from the measurement catalog."
            )
    return errors, metrics_by_id


def validate_event_schema(schema: Any, model: str) -> list[str]:
    errors: list[str] = []
    if not isinstance(schema, dict):
        return ["Measurement event schema root must be an object."]
    if schema.get("schema") != 1:
        errors.append("Measurement event schema must be 1.")
    if schema.get("kind") != "sdlc-measurement-event-schema":
        errors.append("Measurement event schema kind is invalid.")
    if schema.get("model") != model:
        errors.append("Measurement event schema model must match measurement.model.")
    common = schema.get("common_required")
    if not isinstance(common, list) or not common:
        errors.append("Measurement event schema must declare common_required fields.")
    event_types = schema.get("event_types")
    if not isinstance(event_types, dict) or not event_types:
        errors.append("Measurement event schema must declare event_types.")
    else:
        for event_type, definition in event_types.items():
            if not isinstance(definition, dict):
                errors.append(
                    f"Event type '{event_type}' definition must be an object."
                )
                continue
            required = definition.get("required")
            if not isinstance(required, list):
                errors.append(
                    f"Event type '{event_type}' must declare required fields."
                )
    forbidden = schema.get("privacy_forbidden_fields")
    if not isinstance(forbidden, list) or not forbidden:
        errors.append("Measurement event schema must declare privacy_forbidden_fields.")
    return errors


def validate_contract(config_path: Path, repo_root: Path, evidence_path: Path) -> int:
    errors: list[str] = []
    config: dict[str, Any] = {}
    catalog: Any = None
    event_schema: Any = None
    try:
        config = read_measurement_config(config_path)
    except (OSError, UnicodeError) as exc:
        errors.append(f"Could not read measurement configuration: {exc}")
    required = (
        "model",
        "catalog_path",
        "event_schema_path",
        "events_path",
        "report_path",
        "experiment_path",
        "cohort",
        "change_failure_window_days",
        "time_measurement_method",
        "owner",
        "retention_days",
    )
    for field in required:
        if not str(config.get(field, "")).strip():
            errors.append(f"measurement.{field} is required.")
    model = str(config.get("model", ""))
    if not MODEL_PATTERN.fullmatch(model):
        errors.append("measurement.model must be a versioned lowercase model ID.")
    failure_window = config.get("change_failure_window_days")
    if not str(failure_window).isdigit() or int(failure_window) < 1:
        errors.append(
            "measurement.change_failure_window_days must be a positive integer."
        )
    retention = config.get("retention_days")
    if not str(retention).isdigit() or int(retention) < 1:
        errors.append("measurement.retention_days must be a positive integer.")
    if (
        not isinstance(config.get("time_measurement_method"), str)
        or not config["time_measurement_method"].strip()
    ):
        errors.append("measurement.time_measurement_method must be configured.")
    paths: dict[str, Path] = {}
    for field in (
        "catalog_path",
        "event_schema_path",
        "events_path",
        "report_path",
        "experiment_path",
    ):
        value = config.get(field)
        if not safe_relative_path(value):
            errors.append(
                f"measurement.{field} must be a safe repository-relative path."
            )
        else:
            paths[field] = repo_path(repo_root, value)
    try:
        if "catalog_path" in paths:
            catalog = load_json(paths["catalog_path"])
        if "event_schema_path" in paths:
            event_schema = load_json(paths["event_schema_path"])
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        errors.append(f"Measurement model files could not be loaded: {exc}")
    if event_schema is not None:
        errors.extend(validate_event_schema(event_schema, model))
    if catalog is not None:
        catalog_errors, _ = validate_catalog(catalog, config, event_schema)
        errors.extend(catalog_errors)
    record = {
        "schema": 1,
        "kind": "sdlc-measurement-model-validation",
        "command": "measurement.py validate-contract",
        "model": model,
        "catalog_path": str(config.get("catalog_path", "")),
        "event_schema_path": str(config.get("event_schema_path", "")),
        "exit_code": 0 if not errors else 1,
        "result": "PASS" if not errors else "FAIL",
        "errors": errors,
    }
    write_evidence(evidence_path, record)
    for error in errors:
        print(f"[FAIL] {error}")
    if errors:
        return 1
    print("[PASS] Measurement model, catalog, and event schema are valid.")
    return 0


def parse_timestamp(value: Any) -> dt.datetime | None:
    if not isinstance(value, str) or not value.strip():
        return None
    normalized = value.strip().replace("Z", "+00:00")
    try:
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def parse_period(start: str, end: str) -> tuple[dt.datetime, dt.datetime]:
    start_date = dt.date.fromisoformat(start)
    end_date = dt.date.fromisoformat(end)
    if start_date > end_date:
        raise ValueError("period start must not be after period end")
    start_time = dt.datetime.combine(start_date, dt.time.min, tzinfo=dt.timezone.utc)
    end_time = dt.datetime.combine(
        end_date + dt.timedelta(days=1), dt.time.min, tzinfo=dt.timezone.utc
    )
    return start_time, end_time


def event_in_period(
    event: dict[str, Any], period: tuple[dt.datetime, dt.datetime]
) -> bool:
    timestamp = parse_timestamp(event.get("event_time"))
    return timestamp is not None and period[0] <= timestamp < period[1]


def matches_filters(event: dict[str, Any], filters: dict[str, Any]) -> bool:
    for field, expected in filters.items():
        actual = event.get(field)
        if isinstance(expected, list):
            if actual not in expected:
                return False
        elif actual != expected:
            return False
    return True


def select_events(
    events: list[dict[str, Any]],
    spec: dict[str, Any],
    period: tuple[dt.datetime, dt.datetime],
    cohort: tuple[str, Any] | None = None,
) -> list[dict[str, Any]]:
    event_type = spec.get("event_type")
    event_types = set(event_type if isinstance(event_type, list) else [event_type])
    selected = [
        event
        for event in events
        if event.get("event_type") in event_types
        and event_in_period(event, period)
        and matches_filters(event, spec.get("filters", {}))
    ]
    if cohort:
        field, value = cohort
        selected = [event for event in selected if event.get(field) == value]
    related = spec.get("related_event")
    if isinstance(related, dict):
        related_types = related.get("event_type", [])
        if isinstance(related_types, str):
            related_types = [related_types]
        source_field = related.get("source_field", related.get("join_field"))
        related_field = related.get("related_field", related.get("join_field"))
        related_filters = related.get("filters", {})
        selected = [
            event
            for event in selected
            if source_field
            and any(
                event.get(source_field) == related_event.get(related_field)
                and matches_filters(related_event, related_filters)
                and (
                    (
                        parse_timestamp(related_event.get("event_time")) is not None
                        and parse_timestamp(
                            event.get("completed_at", event.get("event_time"))
                        )
                        is not None
                        and dt.timedelta(0)
                        <= parse_timestamp(related_event.get("event_time"))
                        - parse_timestamp(
                            event.get("completed_at", event.get("event_time"))
                        )
                        <= dt.timedelta(days=float(related["window_days"]))
                    )
                    if related.get("window_days") is not None
                    else event_in_period(related_event, period)
                )
                for related_event in events
                if related_event.get("event_type") in related_types
            )
        ]
    return selected


def source_ids(events: Iterable[dict[str, Any]]) -> dict[str, list[str]]:
    result: dict[str, list[str]] = {
        "event_ids": [],
        "deployment_ids": [],
        "change_ids": [],
        "incident_ids": [],
    }
    for event in events:
        for output, field in (
            ("event_ids", "event_id"),
            ("deployment_ids", "deployment_id"),
            ("change_ids", "change_id"),
            ("incident_ids", "incident_id"),
        ):
            value = event.get(field)
            if isinstance(value, str) and value and value not in result[output]:
                result[output].append(value)
    for values in result.values():
        values.sort()
    return result


def evaluate_operand(
    events: list[dict[str, Any]],
    spec: dict[str, Any],
    period: tuple[dt.datetime, dt.datetime],
    cohort: tuple[str, Any] | None = None,
) -> dict[str, Any]:
    if spec.get("operation") == "period_count":
        return {"value": 1.0, "denominator": 1, "events": []}
    selected = select_events(events, spec, period, cohort)
    operation = spec.get("operation")
    field = spec.get("field")
    values = [event.get(field) for event in selected] if field else []
    if operation == "count":
        value = float(len(selected))
        usable = selected
    elif operation == "count_distinct":
        usable = [event for event in selected if event.get(field) not in (None, "")]
        value = float(len({event[field] for event in usable}))
    elif operation == "count_true":
        usable = [event for event in selected if event.get(field) is True]
        value = float(len(usable))
    elif operation in {"sum", "average"}:
        usable = [
            event
            for event in selected
            if isinstance(event.get(field), (int, float))
            and not isinstance(event.get(field), bool)
        ]
        numeric_values = [float(event[field]) for event in usable]
        value = (
            sum(numeric_values)
            if operation == "sum"
            else (sum(numeric_values) / len(numeric_values) if numeric_values else None)
        )
    else:
        value = None
        usable = []
    return {
        "value": value,
        "denominator": len(usable),
        "events": usable,
        "selected_count": len(selected),
        "missing_values": len(selected) - len(usable),
    }


def evaluate_duration_operand(
    events: list[dict[str, Any]],
    spec: dict[str, Any],
    period: tuple[dt.datetime, dt.datetime],
    cohort: tuple[str, Any] | None = None,
) -> dict[str, Any]:
    selected = select_events(events, spec, period, cohort)
    start_type = spec.get("start_event_type")
    start_field = spec.get("start_field")
    end_field = spec.get("end_field")
    join_field = spec.get("join_field")
    start_join_field = spec.get("start_join_field", join_field)
    durations: list[float] = []
    contributing: list[dict[str, Any]] = []
    for event in selected:
        end_time = parse_timestamp(event.get(end_field))
        start_event = event
        if start_type:
            candidates = [
                candidate
                for candidate in events
                if candidate.get("event_type") == start_type
                and (
                    not join_field
                    or candidate.get(start_join_field) == event.get(join_field)
                )
            ]
            candidates.sort(
                key=lambda candidate: parse_timestamp(candidate.get(start_field))
                or dt.datetime.max.replace(tzinfo=dt.timezone.utc)
            )
            start_event = candidates[0] if candidates else None
        start_time = (
            parse_timestamp(start_event.get(start_field)) if start_event else None
        )
        if not start_time or not end_time:
            continue
        paused = event.get("paused_seconds", 0)
        if not isinstance(paused, (int, float)) or isinstance(paused, bool):
            paused = 0
        duration = (end_time - start_time).total_seconds() - float(paused)
        if duration < 0:
            continue
        durations.append(duration)
        contributing.append(event)
        if start_event is not event:
            contributing.append(start_event)
    return {
        "value": sum(durations) / len(durations) if durations else None,
        "denominator": len(durations),
        "events": contributing,
        "selected_count": len(selected),
        "missing_values": len(selected) - len(durations),
    }


def evaluate_formula(
    events: list[dict[str, Any]],
    formula: dict[str, Any],
    period: tuple[dt.datetime, dt.datetime],
    cohort: tuple[str, Any] | None = None,
) -> dict[str, Any]:
    numerator_spec = formula["numerator"]
    if formula.get("operation") == "average_duration":
        numerator = evaluate_duration_operand(events, numerator_spec, period, cohort)
    else:
        numerator = evaluate_operand(events, numerator_spec, period, cohort)
    denominator = evaluate_operand(events, formula["denominator"], period, cohort)
    denominator_value = denominator.get("value")
    numerator_value = numerator.get("value")
    if not isinstance(denominator_value, (int, float)) or denominator_value <= 0:
        value = None
        status = "NO_DATA"
        reason = "zero_or_missing_denominator"
    elif numerator_value is None:
        value = None
        status = "INCOMPLETE"
        reason = "missing_numerator_values"
    else:
        value = (
            float(numerator_value)
            if formula.get("operation") == "average_duration"
            else float(numerator_value) / float(denominator_value)
        )
        status = "OK"
        reason = ""
    return {
        "value": value,
        "numerator": numerator_value,
        "denominator": denominator_value,
        "status": status,
        "reason": reason,
        "events": numerator.get("events", []) + denominator.get("events", []),
        "missing_values": numerator.get("missing_values", 0)
        + denominator.get("missing_values", 0),
    }


def metric_cohort_values(
    events: list[dict[str, Any]],
    metric: dict[str, Any],
    period: tuple[dt.datetime, dt.datetime],
) -> list[Any]:
    field = metric["cohort"]["field"]
    event_type = metric["formula"]["numerator"].get("event_type")
    values = {
        event.get(field)
        for event in events
        if event.get("event_type") == event_type
        and event_in_period(event, period)
        and event.get(field) not in (None, "")
    }
    return sorted(values, key=str)


def confidence_for(denominator: Any, completeness: float) -> dict[str, Any]:
    if not isinstance(denominator, (int, float)) or denominator <= 0:
        score = 0.0
    else:
        score = round(min(1.0, float(denominator) / 10.0) * completeness, 3)
    level = "high" if score >= 0.8 else "medium" if score >= 0.5 else "low"
    return {
        "method": "denominator-size-and-event-completeness",
        "score": score,
        "level": level,
    }


def metric_report(
    events: list[dict[str, Any]],
    metric: dict[str, Any],
    period: tuple[dt.datetime, dt.datetime],
    baseline_value: Any,
) -> dict[str, Any]:
    formula = metric["formula"]
    result = evaluate_formula(events, formula, period)
    contributing = result.pop("events", [])
    cohort_field = metric["cohort"]["field"]
    cohort_results: dict[str, Any] = {}
    for cohort_value in metric_cohort_values(events, metric, period):
        cohort_result = evaluate_formula(
            events, formula, period, (cohort_field, cohort_value)
        )
        cohort_results[str(cohort_value)] = {
            "value": cohort_result["value"],
            "numerator": cohort_result["numerator"],
            "denominator": cohort_result["denominator"],
            "status": cohort_result["status"],
        }
    breakdown: dict[str, Any] = {}
    breakdown_field = metric.get("breakdown_field")
    if isinstance(breakdown_field, str) and breakdown_field:
        numerator_events = select_events(events, formula["numerator"], period)
        breakdown_values = sorted(
            {
                event.get(breakdown_field)
                for event in numerator_events
                if event.get(breakdown_field) not in (None, "")
            },
            key=str,
        )
        for breakdown_value in breakdown_values:
            numerator_spec = dict(formula["numerator"])
            filters = dict(numerator_spec.get("filters", {}))
            filters[breakdown_field] = breakdown_value
            numerator_spec["filters"] = filters
            breakdown_formula = dict(formula)
            breakdown_formula["numerator"] = numerator_spec
            breakdown_result = evaluate_formula(events, breakdown_formula, period)
            breakdown[str(breakdown_value)] = {
                "value": breakdown_result["value"],
                "numerator": breakdown_result["numerator"],
                "denominator": breakdown_result["denominator"],
                "status": breakdown_result["status"],
            }
    value = result["value"]
    delta = None
    delta_percent = None
    if isinstance(value, (int, float)) and isinstance(baseline_value, (int, float)):
        delta = value - baseline_value
        if baseline_value != 0:
            delta_percent = delta / baseline_value
    desired_direction = metric.get("desired_direction", "higher")
    deteriorated = bool(
        delta is not None
        and (
            (desired_direction == "higher" and delta < 0)
            or (desired_direction == "lower" and delta > 0)
        )
    )
    completeness = (
        0.0
        if result["status"] != "OK"
        else max(
            0.0, 1.0 - (result.get("missing_values", 0) / max(1, result["denominator"]))
        )
    )
    return {
        "id": metric["id"],
        "name": metric["name"],
        "category": metric["category"],
        "unit": metric["unit"],
        "value": value,
        "baseline_value": baseline_value,
        "numerator": result["numerator"],
        "denominator": result["denominator"],
        "status": result["status"],
        "reason": result["reason"],
        "formula": formula,
        "cohort": {"field": cohort_field, "values": cohort_results},
        "breakdown": breakdown,
        "completeness": {
            "score": round(completeness, 3),
            "missing_values": result.get("missing_values", 0),
        },
        "confidence": confidence_for(result["denominator"], completeness),
        "trend": {
            "delta": delta,
            "delta_percent": delta_percent,
            "desired_direction": desired_direction,
            "deteriorated": deteriorated,
        },
        "source_ids": source_ids(contributing),
    }


def snapshot_period(snapshot_path: Path) -> tuple[str, str]:
    snapshot = load_json(snapshot_path)
    period = snapshot.get("period", {}) if isinstance(snapshot, dict) else {}
    start, end = period.get("start"), period.get("end")
    if not isinstance(start, str) or not isinstance(end, str):
        raise ValueError("Snapshot period must contain start and end dates.")
    parse_period(start, end)
    return start, end


def validate_events(
    events_path: Path,
    event_schema: dict[str, Any],
    model: str,
    evidence_path: Path,
    measurement_method: str | None = None,
) -> tuple[list[dict[str, Any]], list[str], dict[str, int]]:
    errors: list[str] = []
    events: list[dict[str, Any]] = []
    stats = {"lines": 0, "valid": 0, "duplicate_event_ids": 0}
    if not events_path.is_file():
        errors.append(f"Measurement events file does not exist: {events_path}")
    else:
        seen_ids: set[str] = set()
        common = event_schema.get("common_required", [])
        definitions = event_schema.get("event_types", {})
        with events_path.open(encoding="utf-8") as handle:
            for line_number, line in enumerate(handle, 1):
                if not line.strip():
                    continue
                stats["lines"] += 1
                try:
                    event = json.loads(line)
                except json.JSONDecodeError as exc:
                    errors.append(f"Event line {line_number} is not valid JSON: {exc}")
                    continue
                if not isinstance(event, dict):
                    errors.append(f"Event line {line_number} must be a JSON object.")
                    continue
                privacy_error = contains_forbidden_key(event)
                if privacy_error:
                    errors.append(f"Event line {line_number}: {privacy_error}")
                event_type = event.get("event_type")
                definition = definitions.get(event_type)
                if not isinstance(definition, dict):
                    errors.append(
                        f"Event line {line_number} uses unknown event_type '{event_type}'."
                    )
                    continue
                for field in list(common) + list(definition.get("required", [])):
                    if field not in event or event[field] in (None, ""):
                        errors.append(
                            f"Event line {line_number} is missing required field '{field}'."
                        )
                if (
                    measurement_method
                    and event_type == "time_measurement"
                    and event.get("method") != measurement_method
                ):
                    errors.append(
                        f"Event line {line_number} time measurement method must be '{measurement_method}'."
                    )
                if event.get("model") != model:
                    errors.append(f"Event line {line_number} model must be '{model}'.")
                if not parse_timestamp(event.get("event_time")):
                    errors.append(
                        f"Event line {line_number} event_time must be an ISO timestamp with timezone."
                    )
                event_id = event.get("event_id")
                if isinstance(event_id, str) and event_id:
                    if event_id in seen_ids:
                        stats["duplicate_event_ids"] += 1
                        errors.append(f"Event ID '{event_id}' occurs more than once.")
                    seen_ids.add(event_id)
                events.append(event)
                stats["valid"] += 1
    record = {
        "schema": 1,
        "kind": "sdlc-measurement-event-validation",
        "command": "measurement.py validate-events",
        "model": model,
        "events_path": str(events_path),
        "stats": stats,
        "exit_code": 0 if not errors else 1,
        "result": "PASS" if not errors else "FAIL",
        "errors": errors,
    }
    write_evidence(evidence_path, record)
    return events, errors, stats


def read_snapshot_metrics(snapshot_path: Path) -> dict[str, Any]:
    try:
        snapshot = load_json(snapshot_path)
    except (OSError, json.JSONDecodeError):
        return {}
    metrics = snapshot.get("metrics", []) if isinstance(snapshot, dict) else []
    return {
        metric.get("id"): metric.get("baseline_value")
        for metric in metrics
        if isinstance(metric, dict) and metric.get("id")
    }


def generate_report(
    config_path: Path, repo_root: Path, output_path: Path, evidence_path: Path
) -> int:
    errors: list[str] = []
    config = read_measurement_config(config_path)
    model = str(config.get("model", ""))
    try:
        catalog_path = repo_path(repo_root, str(config.get("catalog_path", "")))
        schema_path = repo_path(repo_root, str(config.get("event_schema_path", "")))
        events_path = repo_path(repo_root, str(config.get("events_path", "")))
        snapshot_path = repo_path(repo_root, str(config.get("snapshot_path", "")))
    except ValueError as exc:
        errors.append(str(exc))
        catalog_path = schema_path = events_path = snapshot_path = repo_root
    catalog: Any = None
    schema: Any = None
    events: list[dict[str, Any]] = []
    period_start = period_end = ""
    if not errors:
        try:
            catalog = load_json(catalog_path)
            schema = load_json(schema_path)
            period_start, period_end = snapshot_period(snapshot_path)
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
            errors.append(f"Measurement report inputs could not be loaded: {exc}")
    catalog_errors: list[str] = []
    metrics_by_id: dict[str, dict[str, Any]] = {}
    if catalog is not None and schema is not None:
        catalog_errors, metrics_by_id = validate_catalog(catalog, config, schema)
        errors.extend(catalog_errors)
        errors.extend(validate_event_schema(schema, model))
        events, event_errors, _ = validate_events(
            events_path,
            schema,
            model,
            evidence_path.with_name("measurement-event-validation.json"),
            str(config.get("time_measurement_method", "")),
        )
        errors.extend(event_errors)
    baseline_values = (
        read_snapshot_metrics(snapshot_path) if snapshot_path.is_file() else {}
    )
    try:
        period = parse_period(period_start, period_end)
    except ValueError as exc:
        errors.append(f"Measurement report period is invalid: {exc}")
        period = parse_period("1970-01-01", "1970-01-01")
    metric_reports: list[dict[str, Any]] = []
    for metric_id in configured_metric_ids(config):
        metric = metrics_by_id.get(metric_id)
        if not metric:
            continue
        metric_reports.append(
            metric_report(events, metric, period, baseline_values.get(metric_id))
        )
    missing_event_types = sorted(
        {
            metric["formula"]["numerator"].get("event_type")
            for metric in (
                metrics_by_id.get(metric_id)
                for metric_id in configured_metric_ids(config)
            )
            if metric
            and metric["formula"]["numerator"].get("event_type")
            not in {event.get("event_type") for event in events}
        }
    )
    for metric_report_item in metric_reports:
        if metric_report_item["status"] != "OK":
            errors.append(
                f"Metric '{metric_report_item['id']}' has no usable denominator or numerator."
            )
    complete = not errors and all(item["status"] == "OK" for item in metric_reports)
    report = {
        "schema": 1,
        "kind": "sdlc-measurement-report",
        "model": model,
        "model_version": model,
        "cohort": {"name": str(config.get("cohort", "")), "field": "service_id"},
        "period": {"start": period_start, "end": period_end},
        "generated_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "metrics": metric_reports,
        "completeness": {
            "status": "COMPLETE" if complete else "INCOMPLETE",
            "score": round(
                sum(item["completeness"]["score"] for item in metric_reports)
                / max(1, len(metric_reports)),
                3,
            ),
            "event_count": len(events),
            "missing_event_types": missing_event_types,
            "late_event_count": sum(
                1 for event in events if not event_in_period(event, period)
            ),
        },
        "sources": {
            "events": str(config.get("events_path", "")),
            "snapshot": str(config.get("snapshot_path", "")),
            "retained_evidence": [
                str(config.get("events_path", "")),
                str(config.get("snapshot_path", "")),
            ],
        },
        "exit_code": 0 if complete else 1,
        "result": "PASS" if complete else "FAIL",
        "errors": errors,
    }
    write_evidence(output_path, report)
    write_evidence(
        evidence_path,
        {
            "schema": 1,
            "kind": "sdlc-measurement-report-validation",
            "command": "measurement.py report",
            "model": model,
            "report_path": str(output_path),
            "exit_code": 0 if complete else 1,
            "result": "PASS" if complete else "FAIL",
            "errors": errors,
        },
    )
    for error in errors:
        print(f"[FAIL] {error}")
    if not errors:
        print(f"[PASS] Measurement report written: {output_path}")
    return 0 if complete else 1


def validate_review(
    config_path: Path, repo_root: Path, report_path: Path, evidence_path: Path
) -> int:
    errors: list[str] = []
    config = read_measurement_config(config_path)
    model = str(config.get("model", ""))
    if not report_path.is_file():
        errors.append(f"Measurement report does not exist: {report_path}")
        report: dict[str, Any] = {}
    else:
        try:
            report = load_json(report_path)
        except (OSError, json.JSONDecodeError) as exc:
            errors.append(f"Measurement report is not valid JSON: {exc}")
            report = {}
    if report.get("model") != model:
        errors.append(
            "Measurement review report model does not match measurement.model."
        )
    try:
        experiment_path = repo_path(repo_root, str(config.get("experiment_path", "")))
        experiments_document = load_json(experiment_path)
    except (ValueError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        errors.append(f"Measurement experiments could not be loaded: {exc}")
        experiments_document = {}
    if isinstance(experiments_document, dict):
        if experiments_document.get("schema") != 1:
            errors.append("Measurement experiments schema must be 1.")
        if experiments_document.get("model") != model:
            errors.append("Measurement experiments model must match measurement.model.")
        experiments = experiments_document.get("experiments", [])
    else:
        errors.append("Measurement experiments root must be an object.")
        experiments = []
    if not isinstance(experiments, list):
        errors.append("Measurement experiments must be an array.")
        experiments = []
    experiment_by_metric: dict[str, list[dict[str, Any]]] = {}
    for index, experiment in enumerate(experiments):
        if not isinstance(experiment, dict):
            errors.append(f"Experiment at index {index} must be an object.")
            continue
        privacy_error = contains_forbidden_key(experiment)
        if privacy_error:
            errors.append(f"Experiment at index {index}: {privacy_error}")
        for field in ("id", "hypothesis", "intervention", "observed_effect", "owner"):
            if (
                not isinstance(experiment.get(field), str)
                or not experiment[field].strip()
            ):
                errors.append(f"Experiment at index {index} must declare {field}.")
        expected_measure = experiment.get("expected_measure")
        metric_id = (
            expected_measure.get("metric_id")
            if isinstance(expected_measure, dict)
            else None
        )
        if not isinstance(metric_id, str) or not metric_id:
            errors.append(
                f"Experiment at index {index} must declare expected_measure.metric_id."
            )
        else:
            experiment_by_metric.setdefault(metric_id, []).append(experiment)
        decision = experiment.get("decision")
        if decision not in {"PROPOSED", "ACCEPTED", "REJECTED", "CONTINUE"}:
            errors.append(f"Experiment at index {index} decision is invalid.")
        regression = experiment.get("regression_check")
        if decision == "ACCEPTED":
            if not isinstance(regression, dict) or regression.get("status") not in {
                "PASS",
                "NO_REGRESSION",
            }:
                errors.append(
                    f"Accepted experiment at index {index} requires a passing regression_check."
                )
            evidence = experiment.get("evidence")
            if not safe_relative_path(evidence) or not (repo_root / evidence).is_file():
                errors.append(
                    f"Accepted experiment at index {index} requires retained evidence."
                )
    deteriorated = [
        item.get("id")
        for item in report.get("metrics", [])
        if isinstance(item, dict) and item.get("trend", {}).get("deteriorated") is True
    ]
    for metric_id in deteriorated:
        candidates = experiment_by_metric.get(metric_id, [])
        if not any(
            candidate.get("decision") in {"ACCEPTED", "CONTINUE", "PROPOSED"}
            and candidate.get("observed_effect")
            for candidate in candidates
        ):
            errors.append(
                f"Deteriorating metric '{metric_id}' must have a tracked improvement experiment."
            )
    record = {
        "schema": 1,
        "kind": "sdlc-measurement-review-validation",
        "command": "measurement.py validate-review",
        "model": model,
        "report_path": str(report_path),
        "deteriorating_metrics": deteriorated,
        "experiment_count": len(experiments),
        "exit_code": 0 if not errors else 1,
        "result": "PASS" if not errors else "FAIL",
        "errors": errors,
    }
    write_evidence(evidence_path, record)
    for error in errors:
        print(f"[FAIL] {error}")
    if not errors:
        print("[PASS] Measurement review and improvement experiments are valid.")
    return 0 if not errors else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    contract = subparsers.add_parser("validate-contract")
    contract.add_argument("--config-path", required=True, type=Path)
    contract.add_argument("--repo-root", required=True, type=Path)
    contract.add_argument("--evidence-path", required=True, type=Path)
    report = subparsers.add_parser("report")
    report.add_argument("--config-path", required=True, type=Path)
    report.add_argument("--repo-root", required=True, type=Path)
    report.add_argument("--output-path", required=True, type=Path)
    report.add_argument("--evidence-path", required=True, type=Path)
    review = subparsers.add_parser("validate-review")
    review.add_argument("--config-path", required=True, type=Path)
    review.add_argument("--repo-root", required=True, type=Path)
    review.add_argument("--report-path", required=True, type=Path)
    review.add_argument("--evidence-path", required=True, type=Path)
    events = subparsers.add_parser("validate-events")
    events.add_argument("--events-path", required=True, type=Path)
    events.add_argument("--event-schema-path", required=True, type=Path)
    events.add_argument("--model", required=True)
    events.add_argument("--evidence-path", required=True, type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "validate-contract":
            return validate_contract(
                args.config_path, args.repo_root, args.evidence_path
            )
        if args.command == "report":
            return generate_report(
                args.config_path, args.repo_root, args.output_path, args.evidence_path
            )
        if args.command == "validate-events":
            schema = load_json(args.event_schema_path)
            _, errors, _ = validate_events(
                args.events_path, schema, args.model, args.evidence_path
            )
            for error in errors:
                print(f"[FAIL] {error}")
            if errors:
                return 1
            print("[PASS] Measurement events are valid.")
            return 0
        return validate_review(
            args.config_path, args.repo_root, args.report_path, args.evidence_path
        )
    except (OSError, UnicodeError, ValueError, KeyError, TypeError) as exc:
        print(f"[FAIL] {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
