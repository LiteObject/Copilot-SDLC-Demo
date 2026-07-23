#!/usr/bin/env python3
"""Evaluate a bounded AI-autonomy request against the repository policy."""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import re
import sys
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

KNOWN_ACTIONS = {
    "read",
    "analyze",
    "propose",
    "edit",
    "command",
    "local_validation",
    "full_validation",
    "branch",
    "pull_request",
    "pull_request_update",
    "network_access",
    "maintenance_batch",
    "commit",
    "merge",
    "deploy",
    "production_config",
    "credential_rotation",
    "secret_access",
    "policy_change",
}
SAFE_ACTIONS = {"read", "analyze", "propose"}
LEVEL_ACTIONS = {
    "L0": SAFE_ACTIONS,
    "L1": SAFE_ACTIONS | {"edit", "command", "local_validation"},
    "L2": SAFE_ACTIONS
    | {
        "edit",
        "command",
        "local_validation",
        "full_validation",
        "branch",
        "pull_request",
        "network_access",
    },
    "L3": SAFE_ACTIONS
    | {
        "edit",
        "command",
        "local_validation",
        "full_validation",
        "branch",
        "pull_request",
        "pull_request_update",
        "network_access",
    },
    "L4": SAFE_ACTIONS
    | {
        "edit",
        "command",
        "local_validation",
        "full_validation",
        "branch",
        "pull_request",
        "pull_request_update",
        "network_access",
        "maintenance_batch",
    },
}
ACTION_ALIASES = {
    "inspect": "read",
    "execute": "command",
    "run_command": "command",
    "validation": "full_validation",
    "create_branch": "branch",
    "create_pr": "pull_request",
    "update_pr": "pull_request_update",
    "network": "network_access",
    "new_network_destination": "network_access",
    "rotate_credentials": "credential_rotation",
    "production_configuration": "production_config",
}
PHASES = {
    "GATHERING_REQS",
    "DESIGN",
    "PLANNING",
    "CODING",
    "REVIEW",
    "TESTING",
    "DEPLOYMENT_READINESS",
    "DONE",
}
FEATURE_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
ISO_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")


def normalize_action(value: str) -> str:
    candidate = value.strip().lower().replace("-", "_")
    return ACTION_ALIASES.get(candidate, candidate)


def strip_comment(value: str) -> str:
    quoted = False
    quote = ""
    for index, character in enumerate(value):
        if character in "\"'":
            if not quoted:
                quoted = True
                quote = character
            elif quote == character:
                quoted = False
        elif (
            character == "#"
            and not quoted
            and (index == 0 or value[index - 1].isspace())
        ):
            return value[:index].rstrip()
    return value.strip()


def split_inline_items(value: str) -> list[str]:
    inner = value.strip()[1:-1].strip()
    if not inner:
        return []
    items: list[str] = []
    start = 0
    quoted = False
    quote = ""
    for index, character in enumerate(inner):
        if character in "\"'":
            if not quoted:
                quoted = True
                quote = character
            elif quote == character:
                quoted = False
        elif character == "," and not quoted:
            items.append(inner[start:index].strip())
            start = index + 1
    items.append(inner[start:].strip())
    return [parse_scalar(item) for item in items if item]


def parse_scalar(value: str) -> str:
    result = strip_comment(value).strip()
    if len(result) >= 2 and result[0] == result[-1] and result[0] in "\"'":
        result = result[1:-1]
        if value.strip().startswith('"'):
            result = result.replace('\\"', '"')
    return result


def read_governance(config_path: Path) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    in_section = False
    for raw_line in config_path.read_text(encoding="utf-8-sig").splitlines():
        line = raw_line.rstrip("\r")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if not line.startswith((" ", "\t")):
            in_section = stripped == "ai_governance:"
            continue
        if not in_section:
            continue
        match = re.match(r"^[ \t]+([A-Za-z0-9_]+):[ \t]*(.*)$", line)
        if not match:
            continue
        raw_value = strip_comment(match.group(2))
        fields[match.group(1)] = (
            split_inline_items(raw_value)
            if raw_value.startswith("[") and raw_value.endswith("]")
            else parse_scalar(raw_value)
        )
    return fields


def get_list(fields: dict[str, Any], name: str) -> list[str] | None:
    value = fields.get(name)
    if value is None:
        return None
    if isinstance(value, list):
        return [str(item) for item in value]
    return None


def safe_relative_path(value: str) -> bool:
    normalized = value.replace("\\", "/")
    return (
        bool(normalized)
        and not normalized.startswith("/")
        and not re.match(r"^[A-Za-z]:/", normalized)
        and not any(part == ".." for part in normalized.split("/"))
    )


def parse_time(value: str) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed.astimezone(timezone.utc) if parsed.tzinfo else None


def parse_now(value: str) -> datetime:
    parsed = parse_time(value)
    if parsed is None:
        raise ValueError("--now must be an ISO-8601 UTC timestamp ending in Z.")
    return parsed


def parse_positive_int(value: Any, name: str, allow_zero: bool = False) -> int:
    text = str(value) if value is not None else ""
    if not re.fullmatch(r"\d+", text):
        raise ValueError(f"{name} must be an integer.")
    number = int(text)
    if number == 0 and not allow_zero:
        raise ValueError(f"{name} must be greater than zero.")
    return number


def validate_policy(
    fields: dict[str, Any], now: datetime
) -> tuple[list[str], dict[str, Any]]:
    if str(fields.get("enabled", "false")).lower() != "true":
        return [], {
            "enabled": False,
            "level": "L0",
            "policy_version": "",
            "expires_at": None,
        }

    errors: list[str] = []
    level = str(fields.get("autonomy_level", ""))
    if level not in LEVEL_ACTIONS:
        errors.append("autonomy_level must be L0, L1, L2, L3, or L4.")
        level = "L0"
    policy_version = str(fields.get("policy_version", "")).strip()
    if not policy_version:
        errors.append("policy_version is required.")
    expires_text = str(fields.get("policy_expires_at", "")).strip()
    expires_at = parse_time(expires_text)
    if not ISO_PATTERN.fullmatch(expires_text) or expires_at is None:
        errors.append(
            "policy_expires_at must be an ISO-8601 UTC timestamp ending in Z."
        )
    elif expires_at <= now:
        errors.append("policy_expires_at has expired.")
    try:
        max_iterations = parse_positive_int(
            fields.get("max_iterations"), "max_iterations"
        )
    except ValueError as error:
        errors.append(str(error))
        max_iterations = 1
    try:
        max_changed_files = parse_positive_int(
            fields.get("max_changed_files"), "max_changed_files", allow_zero=True
        )
    except ValueError as error:
        errors.append(str(error))
        max_changed_files = 0
    try:
        approval_expiration_hours = parse_positive_int(
            fields.get("approval_expiration_hours"), "approval_expiration_hours"
        )
    except ValueError as error:
        errors.append(str(error))
        approval_expiration_hours = 1

    action_classes = get_list(fields, "action_classes")
    if action_classes is None:
        errors.append("action_classes must be an inline YAML list.")
        action_classes = []
    normalized_classes = {normalize_action(item) for item in action_classes}
    for action in normalized_classes:
        if action not in KNOWN_ACTIONS:
            errors.append(f"Unsupported action class: {action}.")

    allowed_branches = get_list(fields, "allowed_branches")
    if allowed_branches is None:
        errors.append("allowed_branches must be an inline YAML list.")
        allowed_branches = []
    for branch in allowed_branches:
        if (
            not branch
            or any(character.isspace() for character in branch)
            or ".." in branch
        ):
            errors.append(f"Invalid allowed branch pattern: {branch}.")

    restricted = get_list(fields, "restricted_actions")
    approval_actions = get_list(fields, "approval_required_actions")
    if restricted is None or approval_actions is None:
        errors.append(
            "restricted_actions and approval_required_actions must be inline YAML lists."
        )
        restricted = restricted or []
        approval_actions = approval_actions or []
    restricted_normalized = {normalize_action(item) for item in restricted}
    approval_normalized = {normalize_action(item) for item in approval_actions}
    for action in restricted_normalized:
        if action not in approval_normalized:
            errors.append(f"Restricted action must require approval: {action}.")
        if action not in normalized_classes:
            errors.append(
                f"Restricted action must be listed in action_classes: {action}."
            )

    requirements = get_list(fields, "approval_requirements")
    requirement_map: dict[str, str] = {}
    if requirements is None:
        errors.append("approval_requirements must be an inline YAML list.")
        requirements = []
    for item in requirements:
        if "=" not in item:
            errors.append(f"Invalid approval requirement: {item}.")
            continue
        action_text, mode = item.split("=", 1)
        action = normalize_action(action_text)
        mode = mode.strip().lower()
        if action not in KNOWN_ACTIONS or mode not in {"human", "policy", "none"}:
            errors.append(f"Invalid approval requirement: {item}.")
        else:
            requirement_map[action] = mode
    for action in restricted_normalized:
        if requirement_map.get(action) != "human":
            errors.append(
                f"Restricted action must have a human approval requirement: {action}."
            )

    tool_allowlist = get_list(fields, "tool_allowlist")
    phase_grants = get_list(fields, "phase_tool_grants")
    if tool_allowlist is None or phase_grants is None:
        errors.append("tool_allowlist and phase_tool_grants must be configured.")
        tool_allowlist = tool_allowlist or []
        phase_grants = phase_grants or []
    phase_map: dict[str, set[str]] = {}
    for grant in phase_grants:
        if "=" not in grant:
            errors.append(f"Invalid phase tool grant: {grant}.")
            continue
        phase, tools = grant.split("=", 1)
        phase_map[phase] = {item for item in tools.split("|") if item}
    sandbox_required = str(fields.get("sandbox_required", "false")).lower()
    sandbox_type = str(fields.get("sandbox_type", ""))
    if sandbox_required not in {"true", "false"}:
        errors.append("sandbox_required must be true or false.")
    if sandbox_required == "true" and sandbox_type == "none":
        errors.append("sandbox_type must not be none when sandbox_required is true.")
    if str(fields.get("command_confirmation_required", "false")).lower() != "true":
        errors.append("command_confirmation_required must be true.")

    return errors, {
        "enabled": True,
        "level": level,
        "policy_version": policy_version,
        "expires_at": expires_at,
        "max_iterations": max_iterations,
        "max_changed_files": max_changed_files,
        "approval_expiration_hours": approval_expiration_hours,
        "action_classes": normalized_classes,
        "allowed_branches": allowed_branches,
        "restricted_actions": restricted_normalized,
        "approval_actions": approval_normalized,
        "approval_requirements": requirement_map,
        "tool_allowlist": set(tool_allowlist),
        "phase_grants": phase_map,
    }


def parse_inline_approval(value: str) -> dict[str, Any]:
    parts = value.split("|", 8)
    if len(parts) != 9:
        raise ValueError(
            "Inline approval must use approval_id|approver|action|scope|policy_version|timestamp|expiration|decision|evidence."
        )
    return {
        "approval_id": parts[0],
        "approver": parts[1],
        "action": parts[2],
        "scope": parts[3],
        "policy_version": parts[4],
        "timestamp": parts[5],
        "expiration": parts[6],
        "decision": parts[7],
        "evidence": parts[8],
    }


def load_approval(
    args: argparse.Namespace, repo_root: Path
) -> tuple[dict[str, Any] | None, str | None]:
    if args.approval_record and args.approval:
        return None, "Use only one approval record input."
    if args.approval:
        try:
            return parse_inline_approval(args.approval), None
        except ValueError as error:
            return None, str(error)
    if not args.approval_record:
        return None, None
    path = Path(args.approval_record)
    if not path.is_absolute():
        path = repo_root / path
    try:
        value = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, json.JSONDecodeError) as error:
        return None, f"Could not read approval record: {error}"
    if not isinstance(value, dict):
        return None, "Approval record must be a JSON object."
    return value, None


def scope_values(approval: dict[str, Any]) -> dict[str, Any]:
    scope = approval.get("scope", {})
    if isinstance(scope, dict):
        result = dict(scope)
    else:
        result = {}
        for item in str(scope).split(";"):
            if "=" in item:
                key, value = item.split("=", 1)
                result[key.strip()] = value.strip()
    if "feature_id" not in result and approval.get("feature_id"):
        result["feature_id"] = approval["feature_id"]
    if "phase" not in result and approval.get("phase"):
        result["phase"] = approval["phase"]
    if "branch" not in result and approval.get("branch"):
        result["branch"] = approval["branch"]
    files = result.get("files", result.get("changed_files", []))
    if isinstance(files, str):
        files = [item for item in files.split(",") if item]
    result["files"] = list(files) if isinstance(files, list) else []
    return result


def validate_approval(
    approval: dict[str, Any],
    action: str,
    args: argparse.Namespace,
    policy: dict[str, Any],
    now: datetime,
) -> tuple[str | None, str | None]:
    approval_id = str(approval.get("approval_id", approval.get("id", ""))).strip()
    if (
        not approval_id
        or not str(approval.get("approver", "")).strip()
        or not str(approval.get("evidence", "")).strip()
    ):
        return (
            "APPROVAL_INVALID",
            "Approval requires approval_id, approver, and evidence.",
        )
    if normalize_action(str(approval.get("action", ""))) != action:
        return (
            "APPROVAL_ACTION_MISMATCH",
            "Approval action is outside the requested action scope.",
        )
    if str(approval.get("policy_version", "")).strip() != policy["policy_version"]:
        return (
            "APPROVAL_POLICY_MISMATCH",
            "Approval policy version does not match the active policy.",
        )
    if str(approval.get("decision", "")).strip() != "APPROVED":
        return "APPROVAL_NOT_APPROVED", "Approval decision is not APPROVED."
    timestamp_text = str(
        approval.get("timestamp", approval.get("issued_at", ""))
    ).strip()
    expiration_text = str(
        approval.get("expiration", approval.get("expires_at", ""))
    ).strip()
    timestamp = parse_time(timestamp_text)
    expiration = parse_time(expiration_text)
    if timestamp is None or expiration is None:
        return (
            "APPROVAL_INVALID",
            "Approval timestamp and expiration must be ISO-8601 UTC timestamps.",
        )
    if timestamp > now:
        return "APPROVAL_INVALID", "Approval timestamp is in the future."
    if expiration <= now:
        return "APPROVAL_EXPIRED", "Approval has expired."
    if expiration > timestamp + timedelta(hours=policy["approval_expiration_hours"]):
        return (
            "APPROVAL_INVALID",
            "Approval expiration exceeds the configured approval lifetime.",
        )
    if policy["expires_at"] is not None and expiration > policy["expires_at"]:
        return "APPROVAL_INVALID", "Approval expires after the active policy."

    scope = scope_values(approval)
    if scope.get("feature_id", "") != (args.feature_id or ""):
        return (
            "APPROVAL_SCOPE_MISMATCH",
            "Approval feature scope does not match the request.",
        )
    if scope.get("phase") and scope["phase"] != args.phase:
        return (
            "APPROVAL_SCOPE_MISMATCH",
            "Approval phase scope does not match the request.",
        )
    if scope.get("branch"):
        if not args.branch or not fnmatch.fnmatchcase(
            args.branch, str(scope["branch"])
        ):
            return (
                "APPROVAL_SCOPE_MISMATCH",
                "Approval branch scope does not match the request.",
            )
    for changed_file in args.changed_file:
        if not any(
            fnmatch.fnmatchcase(changed_file, str(pattern))
            for pattern in scope["files"]
        ):
            return (
                "APPROVAL_SCOPE_MISMATCH",
                "A changed file is outside the approval scope.",
            )
    return None, None


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Evaluate a bounded AI-autonomy request."
    )
    result.add_argument("--action", required=True)
    result.add_argument("--phase", required=True)
    result.add_argument("--feature-id", default="")
    result.add_argument("--spec-path", default="")
    result.add_argument("--changed-file", action="append", default=[])
    result.add_argument("--tool-grant", action="append", default=[])
    result.add_argument("--network-destination", action="append", default=[])
    result.add_argument("--branch", default="")
    result.add_argument("--iteration", default="0")
    result.add_argument("--now", default="")
    result.add_argument("--approval-record", default="")
    result.add_argument("--approval", default="")
    result.add_argument("--decision-id", default="")
    result.add_argument("--config-path", default="")
    result.add_argument("--repo-root", default="")
    result.add_argument("--evidence-directory", default=".sdlc/evidence")
    return result


def reason(code: str, message: str, details: list[str] | None = None) -> dict[str, Any]:
    return {"code": code, "message": message, "details": details or []}


def main() -> int:
    args = parser().parse_args()
    repo_root = (
        Path(args.repo_root).resolve()
        if args.repo_root
        else Path(__file__).resolve().parent.parent
    )
    config_path = (
        Path(args.config_path)
        if args.config_path
        else repo_root / ".github" / "sdlc-config.yml"
    )
    if not config_path.is_absolute():
        config_path = repo_root / config_path
    decision_id = args.decision_id or f"AUTO-{uuid.uuid4().hex[:12].upper()}"
    try:
        now = parse_now(args.now) if args.now else datetime.now(timezone.utc)
    except ValueError as error:
        print(
            json.dumps(
                {
                    "schema": 1,
                    "kind": "sdlc-autonomy-decision",
                    "decision": "DENY",
                    "reason_code": "INVALID_TIME",
                    "reason": reason("INVALID_TIME", str(error)),
                },
                separators=(",", ":"),
            )
        )
        return 1

    requested_action = args.action
    action = normalize_action(requested_action)
    policy_errors: list[str] = []
    fields: dict[str, Any] = {}
    try:
        fields = read_governance(config_path)
        policy_errors, policy = validate_policy(fields, now)
    except (OSError, ValueError) as error:
        policy = {
            "enabled": False,
            "level": "L0",
            "policy_version": "",
            "expires_at": None,
        }
        policy_errors = [f"Could not read autonomy policy: {error}"]

    approval, approval_error = load_approval(args, repo_root)
    base = {
        "schema": 1,
        "kind": "sdlc-autonomy-decision",
        "decision_id": decision_id,
        "requested_action": requested_action,
        "action": action,
        "phase": args.phase,
        "feature_id": args.feature_id,
        "spec_path": args.spec_path,
        "changed_files": args.changed_file,
        "tool_grants": args.tool_grant,
        "network_destinations": args.network_destination,
        "branch": args.branch,
        "iteration": args.iteration,
        "autonomy_level": policy.get("level", "L0"),
        "policy_version": policy.get("policy_version", ""),
        "approval_id": (
            str(approval.get("approval_id", approval.get("id", ""))) if approval else ""
        ),
        "evaluated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
    }

    result_reason: dict[str, Any] | None = None
    approved_human = False
    level = policy.get("level", "L0")
    policy_valid = not policy_errors and policy.get("enabled", False)

    if args.phase not in PHASES:
        result_reason = reason(
            "INVALID_PHASE", "Phase is not in the SDLC phase contract."
        )
    elif args.feature_id and not FEATURE_PATTERN.fullmatch(args.feature_id):
        result_reason = reason(
            "INVALID_FEATURE_ID",
            "Feature ID must use lowercase letters, numbers, and single hyphens.",
        )
    elif action not in KNOWN_ACTIONS:
        result_reason = reason("UNKNOWN_ACTION", "Intended action is not recognized.")
    elif not policy_valid and action not in SAFE_ACTIONS:
        result_reason = reason(
            "POLICY_INVALID",
            "Autonomy policy is missing, disabled, expired, or invalid; only L0 read/analyze/propose actions remain available.",
            policy_errors,
        )
    elif policy_valid and action not in policy["action_classes"]:
        result_reason = reason(
            "ACTION_NOT_CONFIGURED",
            "Intended action is not listed in ai_governance.action_classes.",
        )
    elif policy_valid:
        try:
            iteration = parse_positive_int(args.iteration, "iteration", allow_zero=True)
        except ValueError as error:
            result_reason = reason("INVALID_ITERATION", str(error))
            iteration = 0
        if result_reason is None and iteration > policy["max_iterations"]:
            result_reason = reason(
                "ITERATION_LIMIT",
                "Configured autonomy iteration limit is exhausted.",
                ["ESCALATE_TO_HUMAN"],
            )
        if result_reason is None:
            for changed_file in args.changed_file:
                if not safe_relative_path(changed_file) or changed_file.endswith(
                    ("/", "\\")
                ):
                    result_reason = reason(
                        "UNSAFE_CHANGED_FILE",
                        "Changed files must be exact repository-relative paths.",
                    )
                    break
        if (
            result_reason is None
            and len(args.changed_file) > policy["max_changed_files"]
        ):
            result_reason = reason(
                "CHANGED_FILE_LIMIT",
                "Configured autonomy changed-file limit is exhausted.",
                ["ESCALATE_TO_HUMAN"],
            )
        if result_reason is None:
            if (
                action in {"branch", "pull_request", "pull_request_update"}
                and not args.branch
            ):
                result_reason = reason(
                    "BRANCH_REQUIRED",
                    "A branch is required for branch and pull-request actions.",
                )
            elif args.branch and not any(
                fnmatch.fnmatchcase(args.branch, pattern)
                for pattern in policy["allowed_branches"]
            ):
                result_reason = reason(
                    "BRANCH_NOT_ALLOWED",
                    "Branch is outside ai_governance.allowed_branches.",
                )
        if result_reason is None and action == "network_access":
            if not args.network_destination:
                result_reason = reason(
                    "NETWORK_DESTINATION_REQUIRED",
                    "Network access requires an explicit destination.",
                )
            elif any(
                not any(
                    fnmatch.fnmatchcase(destination, pattern)
                    for pattern in fields.get("network_destination_allowlist", [])
                )
                for destination in args.network_destination
            ):
                result_reason = reason(
                    "NETWORK_DESTINATION_NOT_ALLOWLISTED",
                    "A network destination is outside the configured allowlist.",
                )
        if result_reason is None and not args.tool_grant and action not in SAFE_ACTIONS:
            result_reason = reason(
                "TOOL_GRANT_REQUIRED",
                "An intended action must declare at least one tool grant.",
            )
        if result_reason is None:
            for grant in args.tool_grant:
                if grant not in policy["tool_allowlist"]:
                    result_reason = reason(
                        "TOOL_GRANT_NOT_ALLOWLISTED",
                        "A tool grant is outside the global allowlist.",
                    )
                    break
        if result_reason is None:
            phase_tools = policy["phase_grants"].get(args.phase)
            if phase_tools is None:
                result_reason = reason(
                    "PHASE_GRANT_MISSING",
                    "No tool grant is configured for the requested phase.",
                )
            elif any(grant not in phase_tools for grant in args.tool_grant):
                result_reason = reason(
                    "PHASE_GRANT_BREACH",
                    "A tool grant is outside the requested phase boundary.",
                )

        level_allowed = (
            action in LEVEL_ACTIONS[level]
            and action not in policy["restricted_actions"]
        )
        mode = policy["approval_requirements"].get(action)
        if mode is None and action in policy["approval_actions"]:
            mode = "human"
        if action in policy["restricted_actions"]:
            mode = "human"
        if action in {"branch", "pull_request", "network_access"}:
            mode = "human"
        if not level_allowed and mode is None:
            mode = "human"
        if level == "L0" and action not in SAFE_ACTIONS:
            mode = "human"

        if result_reason is None and approval_error:
            result_reason = reason("APPROVAL_INVALID", approval_error)
        if result_reason is None and approval is not None:
            approval_code, approval_message = validate_approval(
                approval, action, args, policy, now
            )
            if approval_code:
                result_reason = reason(
                    approval_code, approval_message or "Approval is invalid."
                )
            else:
                approved_human = str(approval.get("decision", "")).strip() == "APPROVED"
        if result_reason is None and mode == "human" and not approved_human:
            result_reason = reason(
                (
                    "RESTRICTED_ACTION_APPROVAL_REQUIRED"
                    if action in policy["restricted_actions"]
                    else "APPROVAL_REQUIRED"
                ),
                "A scoped, unexpired human approval is required for this action.",
                ["ESCALATE_TO_HUMAN"],
            )
        if (
            result_reason is None
            and mode != "policy"
            and not level_allowed
            and not approved_human
        ):
            result_reason = reason(
                "AUTONOMY_LEVEL_LIMIT",
                f"Action is not permitted at autonomy level {level}.",
                ["ESCALATE_TO_HUMAN"],
            )

    if result_reason is None:
        if policy_valid:
            result_reason = reason(
                "ALLOWED", f"Action is allowed at autonomy level {level}."
            )
        else:
            result_reason = reason(
                "SAFE_L0_FALLBACK",
                "Policy is not active; the request is limited to a safe L0 action.",
            )
    allowed = result_reason["code"] in {"ALLOWED", "SAFE_L0_FALLBACK"}
    base.update(
        {
            "decision": "ALLOW" if allowed else "DENY",
            "allowed": allowed,
            "reason_code": result_reason["code"],
            "reason": result_reason,
            "escalation_required": not allowed,
            "final_disposition": "ALLOWED" if allowed else "ESCALATE",
            "policy_errors": policy_errors,
        }
    )

    evidence_path = ""
    evidence_error = None
    try:
        if not safe_relative_path(args.evidence_directory):
            raise ValueError("evidence directory must be repository-relative")
        evidence_directory = Path(args.evidence_directory)
        if args.feature_id:
            evidence_directory = evidence_directory / args.feature_id
        evidence_file = repo_root / evidence_directory / "autonomy-decisions.jsonl"
        evidence_file.parent.mkdir(parents=True, exist_ok=True)
        evidence_path = (evidence_directory / "autonomy-decisions.jsonl").as_posix()
        base["evidence_path"] = evidence_path
        with evidence_file.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(base, separators=(",", ":")) + "\n")
    except (OSError, ValueError) as error:
        evidence_error = str(error)

    if evidence_error:
        base["decision"] = "DENY"
        base["allowed"] = False
        base["reason_code"] = "EVIDENCE_WRITE_FAILED"
        base["reason"] = reason(
            "EVIDENCE_WRITE_FAILED",
            "The autonomy decision could not be recorded.",
            [evidence_error, "ESCALATE_TO_HUMAN"],
        )
        base["escalation_required"] = True
        base["final_disposition"] = "ESCALATE"
        base["evidence_error"] = evidence_error

    print(json.dumps(base, separators=(",", ":")))
    return 0 if base["decision"] == "ALLOW" else 1


if __name__ == "__main__":
    sys.exit(main())
