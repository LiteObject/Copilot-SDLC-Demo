#!/usr/bin/env python3
"""Canonical parser for the SDLC YAML and JSON contract documents."""

from __future__ import annotations

import argparse
import base64
import csv
import io
import json
import re
import sys
from pathlib import Path
from typing import Any

PARSER_VERSION = "1.0.1"
PARSER_PACKAGE = "PyYAML"
PARSER_PACKAGE_VERSION = "6.0.2"
SCHEMA_VERSION = 1
COMPAT_REMOVAL_VERSION = "2.0.0"

CONFIG_SECTIONS = {
    "stack": {"languages", "frameworks", "package_manager", "package_manifest"},
    "testing": {"framework", "directories"},
    "linting": {"formatters"},
    "validation": {
        "required_tasks",
        "optional_tasks",
        "install_task",
        "evidence_directory",
    },
    "quality_security": {
        "risk_profile",
        "required_test_layers",
        "acceptance_mapping_required",
    },
    "security": {"review_required", "tasks", "blocking_severities"},
    "verification": {
        "coverage_enabled",
        "coverage_task",
        "coverage_provider",
        "coverage_report_path",
        "coverage_changed_line_threshold",
        "coverage_excluded_paths",
        "coverage_required_risk_profiles",
        "mutation_enabled",
        "mutation_task",
        "mutation_provider",
        "mutation_report_path",
        "mutation_threshold",
        "mutation_excluded_paths",
        "mutation_required_risk_profiles",
    },
    "release_assurance": {
        "enabled",
        "artifact_task",
        "artifact_path",
        "sbom_task",
        "sbom_path",
        "sbom_format",
        "require_provenance",
        "provenance_path",
        "require_signed_artifact",
        "signing_task",
        "signature_path",
        "deployment_task",
        "smoke_test_task",
        "rollback_task",
        "release_notes_path",
        "rollback_instructions_path",
        "promotion_environments",
        "required_approvals",
        "deployment_window",
    },
    "operational_readiness": {
        "enabled",
        "service_name",
        "service_owner",
        "on_call",
        "health_endpoint",
        "required_telemetry",
        "required_slis",
        "slo_availability",
        "slo_latency",
        "slo_error_rate",
        "slo_throughput",
        "slo_business_outcome",
        "readiness_review_items",
        "incident_severities",
        "retention_days",
        "readiness_review_path",
        "incident_response_path",
        "alert_policy_path",
        "escalation_policy_path",
        "runbooks",
        "feedback_path",
        "incident_record_path",
        "health_check_task",
        "telemetry_check_task",
        "failure_drill_task",
        "post_release_check_task",
    },
    "ai_governance": {
        "enabled",
        "policy_path",
        "permissions_path",
        "threat_model_path",
        "evaluation_plan_path",
        "evaluation_scenarios_path",
        "ledger_path",
        "evaluation_evidence_path",
        "retention_days",
        "audit_retention_days",
        "approved_providers",
        "approved_models",
        "approved_tenants",
        "permitted_repositories",
        "allowed_data_classifications",
        "prohibited_inputs",
        "tool_allowlist",
        "mcp_server_allowlist",
        "network_destination_allowlist",
        "credential_scope_allowlist",
        "phase_tool_grants",
        "restricted_actions",
        "approval_required_actions",
        "sandbox_required",
        "sandbox_type",
        "command_confirmation_required",
        "untrusted_input_policy",
        "autonomy_level",
        "policy_version",
        "policy_expires_at",
        "max_iterations",
        "max_changed_files",
        "allowed_branches",
        "action_classes",
        "approval_requirements",
        "approval_expiration_hours",
        "evaluation_task",
    },
    "ai_lifecycle": {
        "enabled",
        "risk_tier",
        "risk_owner",
        "intended_uses",
        "prohibited_uses",
        "affected_communities",
        "applicable_laws",
        "human_oversight",
        "contestability",
        "impact_assessment_path",
        "inventory_path",
        "evaluation_plan_path",
        "evaluation_report_path",
        "risk_disposition_path",
        "red_team_plan_path",
        "runtime_controls_path",
        "monitoring_plan_path",
        "rollback_plan_path",
        "decommissioning_plan_path",
        "model_card_path",
        "system_card_path",
        "model_providers",
        "models",
        "prompt_versions",
        "system_instruction_versions",
        "tools",
        "retrieval_sources",
        "embeddings",
        "datasets",
        "evaluation_datasets",
        "safety_filters",
        "fallback_behavior",
        "material_change_triggers",
        "required_metrics",
        "alert_thresholds",
        "monitoring_cadence",
        "reevaluation_cadence",
        "retention_days",
        "require_red_team",
        "require_production_exercise",
        "tool_authorization_required",
        "least_privilege_required",
        "rate_limit_required",
        "cost_limit_required",
        "input_validation_required",
        "output_validation_required",
        "safety_filter_required",
        "pii_handling_required",
        "audit_log_required",
        "human_escalation_required",
        "kill_switch_required",
        "safe_fallback_required",
        "evaluation_task",
        "red_team_task",
        "production_exercise_task",
        "rollback_task",
        "decommission_task",
    },
    "measurement": {
        "enabled",
        "require_completion_gate",
        "model",
        "cohort",
        "change_failure_window_days",
        "time_measurement_method",
        "owner",
        "cadence",
        "retention_days",
        "measurement_plan_path",
        "baseline_path",
        "metric_catalog_path",
        "catalog_path",
        "event_schema_path",
        "events_path",
        "report_path",
        "experiment_path",
        "privacy_review_path",
        "improvement_log_path",
        "quarterly_review_path",
        "snapshot_path",
        "baseline_task",
        "snapshot_task",
        "review_task",
        "baseline_metrics",
        "delivery_metrics",
        "ai_product_metrics_applicable",
        "ai_product_metrics",
        "phase_outcome_metrics",
        "phase_leading_indicators",
    },
    "conventions": {"max_line_length", "indent", "quotes", "semicolons"},
    "integrations": {"copilot_coding_agent", "deployment_readiness_gate"},
    "design_system": {"framework", "a11y_target"},
}

CONFIG_TOP_LEVEL = {"sdlc_config_schema", "tasks", *CONFIG_SECTIONS.keys()}
TASK_NAMES = {
    "install",
    "build",
    "test",
    "lint",
    "type_check",
    "sast",
    "secrets",
    "dependency_audit",
    "license_audit",
    "container_scan",
    "iac_scan",
    "dast",
    "security_tests",
    "coverage",
    "mutation",
    "package",
    "sbom",
    "sign",
    "verify_signature",
    "deploy",
    "smoke_test",
    "rollback",
    "health_check",
    "telemetry_check",
    "failure_drill",
    "post_release_check",
    "agent_evaluation",
    "ai_evaluation",
    "ai_red_team",
    "ai_production_exercise",
    "ai_rollback",
    "ai_decommission",
    "measurement_baseline",
    "measurement_snapshot",
    "measurement_review",
}

MANIFEST_TOP_LEVEL = {"template", "base", "extensions", "ownership"}
MANIFEST_FIELDS = {
    "template": {
        "name",
        "version",
        "supported_installers",
        "compatibility_policy",
        "description",
    },
    "base": {"path", "installs"},
    "extensions": {"*"},
    "ownership": {"template_owned", "project_owned"},
}

SPEC_FIELDS = {
    "sdlc_schema",
    "feature_id",
    "spec_path",
    "current_phase",
    "design_required",
    "deployment_readiness_enabled",
    "operational_readiness_enabled",
    "ai_governance_enabled",
    "ai_lifecycle_enabled",
    "measurement_enabled",
    "security_gate_enabled",
    "review_cycle",
    "revision_commit_sha",
    "revision_tree_digest",
    "last_transition_from",
    "last_transition_to",
    "last_transition_timestamp",
    "last_transition_actor",
    "last_transition_evidence",
    "planned_files",
    "approved_globs",
    "approved_shared_files",
}


class ContractParserError(Exception):
    def __init__(
        self,
        message: str,
        *,
        code: str = "parse_error",
        line: int | None = None,
        column: int | None = None,
        field: str | None = None,
    ) -> None:
        super().__init__(message)
        self.error = {
            "code": code,
            "message": message,
            "line": line,
            "column": column,
            "field": field,
        }


def _mark_location(mark: Any) -> tuple[int | None, int | None]:
    if mark is None:
        return None, None
    return mark.line + 1, mark.column + 1


def _error_from_mark(
    message: str,
    mark: Any,
    *,
    code: str = "parse_error",
    field: str | None = None,
) -> ContractParserError:
    line, column = _mark_location(mark)
    return ContractParserError(
        message, code=code, line=line, column=column, field=field
    )


def _load_yaml_module() -> Any:
    try:
        import yaml
    except ImportError as exc:
        raise ContractParserError(
            "PyYAML==6.0.2 is required for standard contract parsing. Install it with "
            "python -m pip install -r scripts/requirements.txt, or explicitly select "
            "SDLC_PARSER_MODE=compat for legacy installations.",
            code="parser_dependency_missing",
        ) from exc
    actual = str(getattr(yaml, "__version__", ""))
    if actual != PARSER_PACKAGE_VERSION:
        raise ContractParserError(
            f"{PARSER_PACKAGE}=={PARSER_PACKAGE_VERSION} is required for standard contract "
            f"parsing; found {actual or 'unknown'}. Install scripts/requirements.txt.",
            code="parser_dependency_version",
        )
    return yaml


def parser_dependency_status() -> dict[str, str]:
    try:
        import yaml
    except ImportError:
        return {
            "result": "FAIL",
            "package": PARSER_PACKAGE,
            "required": PARSER_PACKAGE_VERSION,
            "actual": "missing",
            "detail": "Install with python -m pip install -r scripts/requirements.txt.",
        }
    actual = str(getattr(yaml, "__version__", "unknown"))
    result = "PASS" if actual == PARSER_PACKAGE_VERSION else "FAIL"
    detail = (
        f"{PARSER_PACKAGE}=={PARSER_PACKAGE_VERSION} is available."
        if result == "PASS"
        else f"Expected {PARSER_PACKAGE}=={PARSER_PACKAGE_VERSION}, found {actual}; install scripts/requirements.txt."
    )
    return {
        "result": result,
        "package": PARSER_PACKAGE,
        "required": PARSER_PACKAGE_VERSION,
        "actual": actual,
        "detail": detail,
    }


def _strict_loader(yaml: Any) -> type:
    allowed_tags = {
        "tag:yaml.org,2002:str",
        "tag:yaml.org,2002:bool",
        "tag:yaml.org,2002:int",
        "tag:yaml.org,2002:float",
        "tag:yaml.org,2002:timestamp",
        "tag:yaml.org,2002:null",
        "tag:yaml.org,2002:seq",
        "tag:yaml.org,2002:map",
    }

    class StrictLoader(yaml.SafeLoader):
        def compose_node(self, parent: Any, index: Any) -> Any:
            if self.check_event(yaml.events.AliasEvent):
                event = self.peek_event()
                raise _error_from_mark(
                    "YAML aliases are not supported; repeat the value explicitly.",
                    event.start_mark,
                    code="unsafe_alias",
                )
            event = self.peek_event()
            if getattr(event, "anchor", None):
                raise _error_from_mark(
                    "YAML anchors are not supported; repeat the value explicitly.",
                    event.start_mark,
                    code="unsafe_anchor",
                )
            node = super().compose_node(parent, index)
            if node.tag not in allowed_tags:
                raise _error_from_mark(
                    f"YAML tag '{node.tag}' is not allowed.",
                    node.start_mark,
                    code="unsafe_tag",
                )
            return node

    return StrictLoader


def _scalar_value(node: Any, field: str | None) -> Any:
    line, column = _mark_location(node.start_mark)
    tag = node.tag
    value = node.value
    if tag == "tag:yaml.org,2002:str":
        return value
    if tag == "tag:yaml.org,2002:null":
        return None
    if tag == "tag:yaml.org,2002:bool":
        if value.lower() not in {"true", "false"}:
            raise ContractParserError(
                f"Ambiguous boolean scalar '{value}'; use true or false.",
                code="ambiguous_scalar",
                line=line,
                column=column,
                field=field,
            )
        return value.lower() == "true"
    if tag == "tag:yaml.org,2002:int":
        if not re.fullmatch(r"-?(?:0|[1-9][0-9]*)", value):
            raise ContractParserError(
                f"Ambiguous integer scalar '{value}'; use a decimal integer without a prefix or separator.",
                code="ambiguous_scalar",
                line=line,
                column=column,
                field=field,
            )
        return int(value)
    if tag == "tag:yaml.org,2002:float":
        if not re.fullmatch(r"-?(?:0|[1-9][0-9]*)\.[0-9]+(?:[eE][+-]?[0-9]+)?", value):
            raise ContractParserError(
                f"Ambiguous float scalar '{value}'; use a decimal value.",
                code="ambiguous_scalar",
                line=line,
                column=column,
                field=field,
            )
        return float(value)
    if tag == "tag:yaml.org,2002:timestamp":
        if not re.fullmatch(
            r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?(?:Z|[+-][0-9]{2}:[0-9]{2})",
            value,
        ):
            raise ContractParserError(
                f"Ambiguous timestamp scalar '{value}'; use an RFC-3339 timestamp.",
                code="ambiguous_scalar",
                line=line,
                column=column,
                field=field,
            )
        return value
    raise ContractParserError(
        f"YAML tag '{tag}' is not allowed.",
        code="unsafe_tag",
        line=line,
        column=column,
        field=field,
    )


def _node_value(
    node: Any, yaml: Any, locations: dict[str, dict[str, int | None]], path: str = ""
) -> Any:
    if isinstance(node, yaml.nodes.ScalarNode):
        if path:
            locations[path] = {
                "line": node.start_mark.line + 1,
                "column": node.start_mark.column + 1,
            }
        return _scalar_value(node, path or None)
    if isinstance(node, yaml.nodes.SequenceNode):
        if path:
            locations[path] = {
                "line": node.start_mark.line + 1,
                "column": node.start_mark.column + 1,
            }
        return [
            _node_value(child, yaml, locations, f"{path}[{index}]")
            for index, child in enumerate(node.value)
        ]
    if isinstance(node, yaml.nodes.MappingNode):
        if path:
            locations[path] = {
                "line": node.start_mark.line + 1,
                "column": node.start_mark.column + 1,
            }
        result: dict[str, Any] = {}
        for key_node, value_node in node.value:
            if (
                not isinstance(key_node, yaml.nodes.ScalarNode)
                or key_node.tag != "tag:yaml.org,2002:str"
            ):
                raise _error_from_mark(
                    "Mapping keys must be strings.",
                    key_node.start_mark,
                    code="invalid_key",
                    field=path or None,
                )
            key = str(_scalar_value(key_node, path or None))
            child_path = f"{path}.{key}" if path else key
            if key == "<<":
                raise _error_from_mark(
                    "YAML merge keys are not supported.",
                    key_node.start_mark,
                    code="unsafe_alias",
                    field=child_path,
                )
            if key in result:
                raise _error_from_mark(
                    f"Duplicate key '{key}'.",
                    key_node.start_mark,
                    code="duplicate_key",
                    field=child_path,
                )
            locations[child_path] = {
                "line": key_node.start_mark.line + 1,
                "column": key_node.start_mark.column + 1,
            }
            result[key] = _node_value(value_node, yaml, locations, child_path)
        return result
    raise ContractParserError("Unsupported YAML node.", code="unsupported_node")


def _parse_json_standard(
    text: str,
) -> tuple[Any, dict[str, dict[str, int | None]], str]:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ContractParserError(
                    f"Duplicate key '{key}'.", code="duplicate_key"
                )
            result[key] = value
        return result

    try:
        document = json.loads(text, object_pairs_hook=reject_duplicates)
    except ContractParserError:
        raise
    except json.JSONDecodeError as exc:
        raise ContractParserError(
            exc.msg,
            code="json_syntax",
            line=exc.lineno,
            column=exc.colno,
        ) from exc
    return document, {}, "json"


def _parse_standard(
    text: str, format_name: str = "yaml"
) -> tuple[Any, dict[str, dict[str, int | None]], str]:
    if format_name == "json":
        return _parse_json_standard(text)
    yaml = _load_yaml_module()
    Loader = _strict_loader(yaml)
    loader = Loader(text)
    try:
        node = loader.get_single_node()
        if node is None:
            return {}, {}, "yaml"
        locations: dict[str, dict[str, int | None]] = {}
        value = _node_value(node, yaml, locations)
        return value, locations, "yaml"
    except ContractParserError:
        raise
    except yaml.YAMLError as exc:
        mark = getattr(exc, "problem_mark", None)
        message = getattr(exc, "problem", None) or str(exc)
        raise _error_from_mark(message, mark, code="yaml_syntax") from exc
    finally:
        loader.dispose()


def _strip_inline_comment(value: str) -> str:
    quote = ""
    escaped = False
    for index, character in enumerate(value):
        if escaped:
            escaped = False
            continue
        if character == "\\" and quote == '"':
            escaped = True
            continue
        if character in {"'", '"'}:
            if not quote:
                quote = character
            elif quote == character:
                quote = ""
            continue
        if (
            character == "#"
            and not quote
            and (index == 0 or value[index - 1].isspace())
        ):
            return value[:index].rstrip()
    return value.rstrip()


def _compat_scalar(value: str, line: int, field: str | None = None) -> Any:
    value = _strip_inline_comment(value.strip())
    if not value:
        return None
    if value.startswith("&") or value.startswith("*") or value.startswith("!"):
        raise ContractParserError(
            "Compatibility parsing rejects anchors, aliases, and tags.",
            code="compat_unsupported_syntax",
            line=line,
            column=1,
            field=field,
        )
    if value[0] in "|>" or (value.startswith("{") and value.endswith("}")):
        raise ContractParserError(
            "Compatibility parsing does not support multiline or flow mappings.",
            code="compat_unsupported_syntax",
            line=line,
            column=1,
            field=field,
        )
    if value.startswith("["):
        if not value.endswith("]"):
            raise ContractParserError(
                "Unterminated compatibility list.",
                code="compat_syntax",
                line=line,
                field=field,
            )
        body = value[1:-1].strip()
        if not body:
            return []
        reader = csv.reader(io.StringIO(body), skipinitialspace=True)
        items = next(reader)
        if any(not item.strip() for item in items):
            raise ContractParserError(
                "Empty list items are not supported.",
                code="compat_syntax",
                line=line,
                field=field,
            )
        return [_compat_scalar(item, line, field) for item in items]
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        if value[0] == "'":
            return value[1:-1]
        try:
            return json.loads(value)
        except json.JSONDecodeError as exc:
            raise ContractParserError(
                "Invalid compatibility quoted scalar.",
                code="compat_syntax",
                line=line,
                field=field,
            ) from exc
    if value.lower() in {"true", "false"}:
        return value.lower() == "true"
    if re.fullmatch(r"-?(?:0|[1-9][0-9]*)", value):
        return int(value)
    if re.fullmatch(r"-?(?:0|[1-9][0-9]*)\.[0-9]+", value):
        return float(value)
    if any(character in value for character in "{}&*!|"):
        raise ContractParserError(
            "Compatibility parsing rejected unsupported scalar syntax.",
            code="compat_unsupported_syntax",
            line=line,
            column=1,
            field=field,
        )
    return value


def _parse_compat(text: str) -> tuple[Any, dict[str, dict[str, int | None]], str]:
    root: dict[str, Any] = {}
    locations: dict[str, dict[str, int | None]] = {}
    section = ""
    task = ""
    active_list = ""
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if "\t" in raw_line:
            raise ContractParserError(
                "Tabs are not supported in compatibility mode.",
                code="compat_syntax",
                line=line_number,
            )
        line = raw_line.rstrip()
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent % 2:
            raise ContractParserError(
                "Compatibility indentation must use multiples of two spaces.",
                code="compat_syntax",
                line=line_number,
            )
        match = re.match(r"^[ ]*(?P<key>[A-Za-z0-9_]+):[ \t]*(?P<value>.*)$", line)
        if match:
            key = match.group("key")
            raw_value = match.group("value")
            active_list = ""
            if indent == 0:
                section = key
                task = ""
                if raw_value.strip():
                    root[key] = _compat_scalar(raw_value, line_number, key)
                    locations[key] = {"line": line_number, "column": indent + 1}
                else:
                    root[key] = {}
                    locations[key] = {"line": line_number, "column": indent + 1}
                continue
            if section == "tasks" and indent == 2:
                task = key
                root.setdefault("tasks", {})[task] = {}
                locations[f"tasks.{task}"] = {"line": line_number, "column": indent + 1}
                continue
            if section == "tasks" and indent >= 4 and task:
                field = f"tasks.{task}.{key}"
                root["tasks"][task][key] = _compat_scalar(raw_value, line_number, field)
                locations[field] = {"line": line_number, "column": indent + 1}
                continue
            if indent != 2:
                raise ContractParserError(
                    "Compatibility mode supports only one nested section level.",
                    code="compat_unsupported_syntax",
                    line=line_number,
                )
            field = f"{section}.{key}"
            if raw_value.strip():
                root.setdefault(section, {})[key] = _compat_scalar(
                    raw_value, line_number, field
                )
                locations[field] = {"line": line_number, "column": indent + 1}
            else:
                root.setdefault(section, {})[key] = []
                active_list = field
                locations[field] = {"line": line_number, "column": indent + 1}
            continue
        list_match = re.match(r"^\s*-\s*(?P<item>.*)$", line)
        if list_match and active_list:
            section_name, key = active_list.split(".", 1)
            item = _compat_scalar(list_match.group("item"), line_number, active_list)
            root.setdefault(section_name, {}).setdefault(key, []).append(item)
            continue
        raise ContractParserError(
            "Unsupported compatibility YAML line.",
            code="compat_unsupported_syntax",
            line=line_number,
        )
    return root, locations, "compat"


def _field_error(
    message: str,
    field: str,
    locations: dict[str, dict[str, int | None]],
    code: str = "unexpected_field",
) -> ContractParserError:
    location = locations.get(field, {})
    return ContractParserError(
        message,
        code=code,
        line=location.get("line"),
        column=location.get("column"),
        field=field,
    )


def _validate_config(
    document: Any, locations: dict[str, dict[str, int | None]]
) -> None:
    if not isinstance(document, dict):
        raise ContractParserError(
            "The SDLC configuration root must be a mapping.", code="invalid_root"
        )
    for key in document:
        if key not in CONFIG_TOP_LEVEL:
            raise _field_error(
                f"Unexpected configuration field '{key}'.", key, locations
            )
    for section, allowed in CONFIG_SECTIONS.items():
        value = document.get(section)
        if value is None:
            continue
        if not isinstance(value, dict):
            raise _field_error(
                f"Configuration section '{section}' must be a mapping.",
                section,
                locations,
                "invalid_section",
            )
        for key in value:
            if key not in allowed:
                raise _field_error(
                    f"Unexpected configuration field '{section}.{key}'.",
                    f"{section}.{key}",
                    locations,
                )
    tasks = document.get("tasks")
    if tasks is not None:
        if not isinstance(tasks, dict):
            raise _field_error(
                "Configuration section 'tasks' must be a mapping.",
                "tasks",
                locations,
                "invalid_section",
            )
        for task_name, task_value in tasks.items():
            if task_name not in TASK_NAMES:
                raise _field_error(
                    f"Unexpected task registry entry 'tasks.{task_name}'.",
                    f"tasks.{task_name}",
                    locations,
                )
            if not isinstance(task_value, dict):
                raise _field_error(
                    f"Task 'tasks.{task_name}' must be a mapping.",
                    f"tasks.{task_name}",
                    locations,
                    "invalid_task",
                )
            for field in task_value:
                if field not in {"executable", "args"}:
                    raise _field_error(
                        f"Unexpected task field 'tasks.{task_name}.{field}'.",
                        f"tasks.{task_name}.{field}",
                        locations,
                    )
            if "args" in task_value and not isinstance(task_value["args"], list):
                raise _field_error(
                    f"Task 'tasks.{task_name}.args' must be a list.",
                    f"tasks.{task_name}.args",
                    locations,
                    "invalid_task",
                )


def _validate_spec(document: Any, locations: dict[str, dict[str, int | None]]) -> None:
    if not isinstance(document, dict):
        raise ContractParserError(
            "Spec front matter must be a mapping.", code="invalid_root"
        )
    for key in document:
        if key not in SPEC_FIELDS and not re.fullmatch(
            r"gate_[a-z0-9_]+(?:_(?:command|commit_sha|tree_digest|timestamp|exit_code|result|evidence|feature_id|spec_path))?",
            key,
        ):
            raise _field_error(
                f"Unexpected spec metadata field '{key}'.", key, locations
            )


def _validate_manifest(
    document: Any, locations: dict[str, dict[str, int | None]]
) -> None:
    if not isinstance(document, dict):
        raise ContractParserError(
            "The template manifest root must be a mapping.", code="invalid_root"
        )
    for key in document:
        if key not in MANIFEST_TOP_LEVEL:
            raise _field_error(f"Unexpected manifest field '{key}'.", key, locations)
    for section, allowed in MANIFEST_FIELDS.items():
        value = document.get(section)
        if value is None:
            continue
        if not isinstance(value, dict):
            raise _field_error(
                f"Manifest section '{section}' must be a mapping.",
                section,
                locations,
                "invalid_section",
            )
        if "*" not in allowed:
            for key in value:
                if key not in allowed:
                    raise _field_error(
                        f"Unexpected manifest field '{section}.{key}'.",
                        f"{section}.{key}",
                        locations,
                    )


def _extract_front_matter(text: str) -> tuple[str, int]:
    lines = text.splitlines(keepends=True)
    if not lines or lines[0].rstrip("\r\n") != "---":
        raise ContractParserError(
            "Document must start with YAML front matter delimited by '---'.",
            code="front_matter_missing",
            line=1,
            column=1,
        )
    for index in range(1, len(lines)):
        if lines[index].rstrip("\r\n") == "---":
            return "".join(lines[1:index]), 1
    raise ContractParserError(
        "YAML front matter closing delimiter '---' is missing.",
        code="front_matter_missing",
        line=len(lines),
        column=1,
    )


def _scalar_text(value: Any) -> str:
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float):
        return format(value, "g")
    return str(value)


def _flatten_config(
    document: dict[str, Any],
) -> tuple[dict[str, str], dict[str, list[str]], dict[str, dict[str, Any]]]:
    values, lists = _flatten_mapping(
        {key: value for key, value in document.items() if key != "tasks"}
    )
    tasks: dict[str, dict[str, Any]] = {}
    for task_name, task_value in document.get("tasks", {}).items():
        tasks[task_name] = {
            "executable": _scalar_text(task_value.get("executable")),
            "args": [_scalar_text(item) for item in task_value.get("args", [])],
        }
    return values, lists, tasks


def _flatten_mapping(
    document: dict[str, Any],
) -> tuple[dict[str, str], dict[str, list[str]]]:
    values: dict[str, str] = {}
    lists: dict[str, list[str]] = {}
    for key, value in document.items():
        if isinstance(value, dict):
            for child_key, child_value in value.items():
                path = f"{key}.{child_key}"
                if isinstance(child_value, list):
                    lists[path] = [_scalar_text(item) for item in child_value]
                elif not isinstance(child_value, dict):
                    values[path] = _scalar_text(child_value)
        elif isinstance(value, list):
            lists[key] = [_scalar_text(item) for item in value]
        else:
            values[key] = _scalar_text(value)
    return values, lists


def parse_contract(
    path: str | Path, contract: str = "sdlc-config", mode: str = "standard"
) -> dict[str, Any]:
    source = Path(path)
    try:
        text = source.read_text(encoding="utf-8-sig")
    except OSError as exc:
        raise ContractParserError(
            f"Could not read contract '{source}': {exc}", code="source_read"
        ) from exc
    parser_mode = mode or "standard"
    if parser_mode not in {"standard", "compat"}:
        raise ContractParserError(
            f"Unsupported parser mode '{parser_mode}'. Use standard or compat.",
            code="parser_mode",
        )
    source_line_offset = 0
    parse_text = text
    if contract == "spec-front-matter":
        parse_text, source_line_offset = _extract_front_matter(text)
    format_name = (
        "json"
        if source.suffix.lower() == ".json" or contract == "task-graph"
        else "yaml"
    )
    if parser_mode == "standard":
        document, locations, format_name = _parse_standard(parse_text, format_name)
    else:
        document, locations, format_name = _parse_compat(parse_text)
    if source_line_offset:
        for location in locations.values():
            if location.get("line") is not None:
                location["line"] = int(location["line"]) + source_line_offset
    if contract == "sdlc-config":
        _validate_config(document, locations)
    elif contract == "spec-front-matter":
        _validate_spec(document, locations)
    elif contract == "template-manifest":
        _validate_manifest(document, locations)
    elif contract not in {"generic", "extension-config", "task-graph"}:
        raise ContractParserError(
            f"Unsupported contract '{contract}'.", code="contract_type"
        )
    values: dict[str, str] = {}
    lists: dict[str, list[str]] = {}
    tasks: dict[str, dict[str, Any]] = {}
    if isinstance(document, dict) and contract == "sdlc-config":
        values, lists, tasks = _flatten_config(document)
    elif isinstance(document, dict) and contract == "spec-front-matter":
        values, lists = _flatten_mapping(document)
    return {
        "schema": SCHEMA_VERSION,
        "kind": "sdlc-contract",
        "contract": contract,
        "contract_schema": 1,
        "parser": {
            "name": PARSER_PACKAGE if parser_mode == "standard" else "compatibility",
            "version": PARSER_PACKAGE_VERSION if parser_mode == "standard" else "0.1.0",
            "mode": parser_mode,
            "deprecated": parser_mode == "compat",
            "removal_version": (
                COMPAT_REMOVAL_VERSION if parser_mode == "compat" else None
            ),
        },
        "source": {
            "path": str(source).replace("\\", "/"),
            "line_count": len(text.splitlines()),
        },
        "document": document,
        "values": values,
        "lists": lists,
        "tasks": tasks,
        "locations": locations,
        "errors": [],
        "warnings": (
            [
                f"Compatibility parser mode is deprecated and will be removed in {COMPAT_REMOVAL_VERSION}."
            ]
            if parser_mode == "compat"
            else []
        ),
        "format": format_name,
    }


def _query_value(document: Any, path: str) -> Any:
    current = document
    if not path:
        return current
    for part in path.split("."):
        if isinstance(current, dict) and part in current:
            current = current[part]
        else:
            raise KeyError(path)
    return current


def _emit_query(value: Any, output_format: str) -> int:
    if output_format == "json":
        sys.stdout.write(json.dumps(value, ensure_ascii=False, separators=(",", ":")))
        sys.stdout.write("\n")
        return 0
    if output_format == "scalar":
        if isinstance(value, (dict, list)):
            return 1
        sys.stdout.write(_scalar_text(value))
        return 0
    if output_format == "nul":
        if not isinstance(value, list):
            return 1
        for item in value:
            sys.stdout.buffer.write(_scalar_text(item).encode("utf-8") + b"\0")
        return 0
    if output_format == "keys-nul":
        if not isinstance(value, dict):
            return 1
        for key in value:
            sys.stdout.buffer.write(str(key).encode("utf-8") + b"\0")
        return 0
    if output_format == "base64":
        sys.stdout.write(
            base64.b64encode(_scalar_text(value).encode("utf-8")).decode("ascii")
        )
        sys.stdout.write("\n")
        return 0
    raise ContractParserError(
        f"Unsupported query format '{output_format}'.", code="query_format"
    )


def _error_payload(
    error: ContractParserError, contract: str, path: str | None = None
) -> dict[str, Any]:
    return {
        "schema": SCHEMA_VERSION,
        "kind": "sdlc-contract-error",
        "contract": contract,
        "source": {"path": str(path).replace("\\", "/") if path else ""},
        "errors": [error.error],
    }


def _write_json(path: str | None, payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    if path and path != "-":
        destination = Path(path)
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(encoded, encoding="utf-8", newline="\n")
    else:
        sys.stdout.write(encoded)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Parse and query SDLC contract documents."
    )
    commands = parser.add_subparsers(dest="command", required=True)

    parse_command = commands.add_parser("parse")
    parse_command.add_argument("--path", required=True)
    parse_command.add_argument(
        "--contract",
        default="sdlc-config",
        choices=[
            "sdlc-config",
            "spec-front-matter",
            "template-manifest",
            "generic",
            "extension-config",
            "task-graph",
        ],
    )
    parse_command.add_argument(
        "--mode", choices=["standard", "compat"], default="standard"
    )
    parse_command.add_argument("--output", default="-")

    query_command = commands.add_parser("query")
    query_command.add_argument("--input", required=True)
    query_command.add_argument("--path", required=True)
    query_command.add_argument(
        "--format",
        choices=["json", "scalar", "nul", "keys-nul", "base64"],
        default="json",
    )

    dependency_command = commands.add_parser("dependency-check")
    dependency_command.add_argument("--json", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        if args.command == "dependency-check":
            status = parser_dependency_status()
            if args.json:
                print(json.dumps(status, ensure_ascii=False))
            else:
                print(f"[{status['result']}] {status['detail']}")
            return 0 if status["result"] == "PASS" else 2
        if args.command == "parse":
            payload = parse_contract(args.path, args.contract, args.mode)
            _write_json(args.output, payload)
            return 0
        try:
            payload = json.loads(Path(args.input).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise ContractParserError(
                f"Could not read canonical parser output '{args.input}': {exc}",
                code="canonical_output",
            ) from exc
        value = _query_value(payload.get("document"), args.path)
        return _emit_query(value, args.format)
    except ContractParserError as exc:
        if args.command == "parse":
            _write_json(
                args.output if args.output != "-" else None,
                _error_payload(exc, args.contract, args.path),
            )
            if args.output != "-":
                print(
                    json.dumps(
                        _error_payload(exc, args.contract, args.path),
                        ensure_ascii=False,
                    ),
                    file=sys.stderr,
                )
        else:
            print(f"[FAIL] {exc}", file=sys.stderr)
        return 2
    except KeyError:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
