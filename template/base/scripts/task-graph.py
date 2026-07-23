#!/usr/bin/env python3
"""Validate and record feature task graphs for the Copilot SDLC template."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

FEATURE_ID_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
TASK_ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9._-]*$")
REFERENCE_PATTERNS = {
    "requirement": re.compile(r"^REQ-[0-9]+$"),
    "acceptance": re.compile(r"^AC-[0-9]+$"),
}
ALLOWED_STATUSES = {"TODO", "IN_PROGRESS", "BLOCKED", "DONE"}
REQUIRED_TASK_FIELDS = {
    "id",
    "title",
    "description",
    "requirement_refs",
    "acceptance_refs",
    "depends_on",
    "planned_files",
    "verification_tasks",
    "status",
    "evidence",
}
EVIDENCE_FIELDS = {
    "task",
    "command",
    "commit_sha",
    "tree_digest",
    "exit_code",
    "result",
    "evidence",
}


def fail(message: str) -> None:
    print(f"[FAIL] {message}")


def pass_message(message: str) -> None:
    print(f"[PASS] {message}")


def normalize_path(value: str) -> str:
    normalized = value.strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def safe_relative_path(value: Any, allow_directory: bool = False) -> bool:
    if not isinstance(value, str):
        return False
    normalized = normalize_path(value)
    if (
        not normalized
        or normalized.startswith("/")
        or re.match(r"^[A-Za-z]:/", normalized)
    ):
        return False
    if re.search(r"(^|/)\.\.(?:/|$)", normalized):
        return False
    if not allow_directory and normalized.endswith("/"):
        return False
    return True


def repo_relative(root: Path, path: Path) -> str:
    return path.resolve().relative_to(root.resolve()).as_posix()


def run_git(root: Path, *arguments: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(root), *arguments],
            check=False,
            capture_output=True,
            text=True,
        )
    except OSError:
        return ""
    if result.returncode != 0:
        return ""
    return result.stdout.strip()


def current_commit(root: Path) -> str:
    return run_git(root, "rev-parse", "HEAD")


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def current_tree_digest(root: Path, spec_relative_path: str) -> str:
    if not current_commit(root):
        return ""
    diff = run_git(
        root,
        "diff",
        "--binary",
        "HEAD",
        "--",
        ".",
        f":(exclude){spec_relative_path}",
        ":(exclude)docs/specs/**/tasks.json",
        ":(exclude).sdlc/**",
    )
    parts = [f"tracked:{diff}"]
    untracked = run_git(root, "ls-files", "--others", "--exclude-standard")
    for relative in sorted(line for line in untracked.splitlines() if line):
        relative = normalize_path(relative)
        if relative == ".sdlc" or relative.startswith(".sdlc/"):
            continue
        path = root / relative
        if path.is_file():
            parts.append(
                f"untracked:{relative}:{hashlib.sha256(path.read_bytes()).hexdigest()}"
            )
    return sha256_text("\n".join(sorted(parts)))


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValueError(f"JSON file not found: {path}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid JSON in {path}: {error}") from error


def read_config_task_ids(path: Path) -> set[str]:
    if not path.is_file():
        raise ValueError(f"Configuration file not found: {path}")
    task_ids: set[str] = set()
    in_tasks = False
    for raw_line in path.read_text(encoding="utf-8").splitlines():
        line = raw_line.rstrip("\r")
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if len(line) == len(line.lstrip()) and stripped == "tasks:":
            in_tasks = True
            continue
        if in_tasks and len(line) == len(line.lstrip()):
            in_tasks = False
        if in_tasks:
            match = re.match(r"^  ([A-Za-z0-9_]+):\s*$", line)
            if match:
                task_ids.add(match.group(1))
    return task_ids


def section_lines(spec_path: Path, heading: str) -> list[str]:
    if not spec_path.is_file():
        return []
    lines = spec_path.read_text(encoding="utf-8").splitlines()
    found = False
    result: list[str] = []
    for line in lines:
        if line == f"## {heading}":
            found = True
            continue
        if found and line.startswith("## "):
            break
        if found:
            result.append(line)
    return result


def spec_references(spec_path: Path) -> tuple[set[str], set[str]]:
    requirements: set[str] = set()
    acceptance: set[str] = set()
    requirement_index = 0
    acceptance_index = 0
    for line in section_lines(spec_path, "Requirements"):
        if re.match(r"^\s*\d+\.\s+\S", line):
            requirement_index += 1
            requirements.add(f"REQ-{requirement_index:03d}")
    for line in section_lines(spec_path, "Acceptance Criteria"):
        if re.match(r"^\s*-\s*\[[ xX]\]\s+\S", line):
            acceptance_index += 1
            acceptance.add(f"AC-{acceptance_index:03d}")
    return requirements, acceptance


def front_matter_list(spec_path: Path, key: str) -> list[str]:
    if not spec_path.is_file():
        return []
    lines = spec_path.read_text(encoding="utf-8").splitlines()
    inside = False
    active = False
    values: list[str] = []
    for raw_line in lines:
        line = raw_line.rstrip("\r")
        if line == "---" and not inside:
            inside = True
            continue
        if line == "---" and inside:
            break
        if not inside:
            continue
        if re.match(rf"^{re.escape(key)}:\s*$", line):
            active = True
            continue
        if re.match(r"^[A-Za-z0-9_]+:", line):
            active = False
        if active:
            match = re.match(r"^\s*-\s*(.+)$", line)
            if match:
                values.append(match.group(1).strip().strip("\"'"))
    return values


def resolve_context(arguments: argparse.Namespace) -> tuple[Path, str, str]:
    root = Path(arguments.repo_root).resolve()
    feature_id = arguments.feature_id or ""
    if feature_id and not FEATURE_ID_PATTERN.fullmatch(feature_id):
        raise ValueError(
            f"feature ID '{feature_id}' is invalid; use lowercase letters, numbers, and single hyphens only"
        )
    if feature_id:
        expected_tasks = f"docs/specs/{feature_id}/tasks.json"
        expected_spec = f"docs/specs/{feature_id}/spec.md"
    else:
        expected_tasks = ""
        expected_spec = "docs/spec.md"
    tasks_path = (
        Path(arguments.tasks_path) if arguments.tasks_path else root / expected_tasks
    )
    if not tasks_path.is_absolute():
        tasks_path = root / tasks_path
    spec_path = (
        Path(arguments.spec_path) if arguments.spec_path else root / expected_spec
    )
    if not spec_path.is_absolute():
        spec_path = root / spec_path
    tasks_relative = repo_relative(root, tasks_path)
    spec_relative = repo_relative(root, spec_path)
    if feature_id and tasks_relative != expected_tasks:
        raise ValueError(
            f"feature '{feature_id}' must use tasks path '{expected_tasks}'"
        )
    if feature_id and spec_relative != expected_spec:
        raise ValueError(f"feature '{feature_id}' must use spec path '{expected_spec}'")
    return root, tasks_relative, spec_relative


def evidence_prefix(feature_id: str) -> str:
    return f".sdlc/evidence/{feature_id}/" if feature_id else ".sdlc/evidence/"


def validate_evidence(
    root: Path,
    feature_id: str,
    spec_relative_path: str,
    task_id: str,
    evidence: Any,
    expected_commit: str,
    expected_tree: str,
    require_pass: bool,
    errors: list[str],
) -> None:
    if not isinstance(evidence, dict):
        errors.append(f"task '{task_id}' evidence entries must be objects")
        return
    missing = sorted(EVIDENCE_FIELDS - set(evidence))
    if missing:
        errors.append(f"task '{task_id}' evidence is missing: {', '.join(missing)}")
        return
    if evidence.get("task") != task_id:
        errors.append(f"task '{task_id}' evidence task must be '{task_id}'")
    if not str(evidence.get("command", "")).strip():
        errors.append(f"task '{task_id}' evidence command is required")
    exit_code = evidence.get("exit_code")
    if not isinstance(exit_code, int):
        errors.append(f"task '{task_id}' evidence exit_code must be an integer")
    elif evidence.get("result") == "PASS" and exit_code != 0:
        errors.append(f"task '{task_id}' PASS evidence must have exit_code 0")
    elif evidence.get("result") != "PASS" and exit_code == 0:
        errors.append(
            f"task '{task_id}' non-PASS evidence must have a non-zero exit_code"
        )
    if evidence.get("result") not in {"PASS", "FAIL"}:
        errors.append(f"task '{task_id}' evidence result must be PASS or FAIL")
    if require_pass and evidence.get("result") != "PASS":
        errors.append(f"task '{task_id}' DONE evidence must have result PASS")
    if expected_commit and evidence.get("commit_sha") != expected_commit:
        errors.append(f"task '{task_id}' evidence commit_sha is stale")
    if expected_tree and evidence.get("tree_digest") != expected_tree:
        errors.append(f"task '{task_id}' evidence tree_digest is stale")
    evidence_path_value = evidence.get("evidence")
    if not safe_relative_path(evidence_path_value):
        errors.append(
            f"task '{task_id}' evidence path must be safe and repository-relative"
        )
        return
    evidence_relative = normalize_path(evidence_path_value)
    if not evidence_relative.startswith(evidence_prefix(feature_id)):
        errors.append(
            f"task '{task_id}' evidence must be under '{evidence_prefix(feature_id)}'"
        )
    evidence_path = root / evidence_relative
    if not evidence_path.is_file():
        errors.append(
            f"task '{task_id}' evidence file does not exist: {evidence_relative}"
        )
        return
    if evidence_path.suffix.lower() != ".json":
        errors.append(f"task '{task_id}' evidence must reference a JSON task record")
        return
    try:
        record = load_json(evidence_path)
    except ValueError as error:
        errors.append(str(error))
        return
    if isinstance(record, dict):
        for key in ("task", "commit_sha", "tree_digest", "result", "exit_code"):
            if key in record and record[key] != evidence[key]:
                errors.append(
                    f"task '{task_id}' evidence record field '{key}' does not match its entry"
                )
        if feature_id and record.get("feature_id") != feature_id:
            errors.append(f"task '{task_id}' evidence record feature_id is incorrect")
        if feature_id and record.get("spec_path") != spec_relative_path:
            errors.append(f"task '{task_id}' evidence record spec_path is incorrect")


def validate_graph(
    arguments: argparse.Namespace,
) -> tuple[dict[str, Any], list[str], Path, str, str]:
    root, tasks_relative, spec_relative = resolve_context(arguments)
    tasks_path = root / tasks_relative
    spec_path = root / spec_relative
    errors: list[str] = []
    try:
        document = load_json(tasks_path)
    except ValueError as error:
        return {}, [str(error)], root, tasks_relative, spec_relative
    if not isinstance(document, dict):
        return (
            {},
            ["task document root must be an object"],
            root,
            tasks_relative,
            spec_relative,
        )
    if document.get("schema_version") != 1:
        errors.append("task document schema_version must be 1")
    feature_id = arguments.feature_id or ""
    if feature_id and document.get("feature_id") != feature_id:
        errors.append(f"task document feature_id must be '{feature_id}'")
    if (
        feature_id
        and normalize_path(str(document.get("spec_path", ""))) != spec_relative
    ):
        errors.append(f"task document spec_path must be '{spec_relative}'")
    tasks = document.get("tasks")
    if not isinstance(tasks, list) or not tasks:
        errors.append("task document tasks must be a non-empty array")
        return document, errors, root, tasks_relative, spec_relative
    config_path = (
        Path(arguments.config_path)
        if arguments.config_path
        else root / ".github/sdlc-config.yml"
    )
    if not config_path.is_absolute():
        config_path = root / config_path
    try:
        allowed_verification_tasks = read_config_task_ids(config_path)
    except ValueError as error:
        errors.append(str(error))
        allowed_verification_tasks = set()
    known_requirements, known_acceptance = spec_references(spec_path)
    if not known_requirements:
        errors.append("spec has no numbered requirements for task graph mapping")
    if not known_acceptance:
        errors.append("spec has no acceptance criteria for task graph mapping")
    task_ids: set[str] = set()
    task_map: dict[str, dict[str, Any]] = {}
    all_task_acceptance: set[str] = set()
    manual_acceptance: set[str] = set()
    manual_verifications = document.get("manual_verifications", [])
    if not isinstance(manual_verifications, list):
        errors.append("manual_verifications must be an array")
        manual_verifications = []
    for manual in manual_verifications:
        if not isinstance(manual, dict):
            errors.append("manual_verifications entries must be objects")
            continue
        acceptance_ref = manual.get("acceptance_ref")
        if not isinstance(acceptance_ref, str) or not REFERENCE_PATTERNS[
            "acceptance"
        ].fullmatch(acceptance_ref):
            errors.append("manual verification acceptance_ref must match AC-###")
            continue
        if (
            not str(manual.get("owner", "")).strip()
            or not str(manual.get("evidence", "")).strip()
        ):
            errors.append(
                f"manual verification '{acceptance_ref}' requires owner and evidence"
            )
        manual_acceptance.add(acceptance_ref)
    for index, task in enumerate(tasks):
        label = f"tasks[{index}]"
        if not isinstance(task, dict):
            errors.append(f"{label} must be an object")
            continue
        missing = sorted(REQUIRED_TASK_FIELDS - set(task))
        if missing:
            errors.append(f"{label} is missing: {', '.join(missing)}")
            continue
        task_id = task.get("id")
        if not isinstance(task_id, str) or not TASK_ID_PATTERN.fullmatch(task_id):
            errors.append(f"{label}.id must be a safe uppercase task identifier")
            continue
        if task_id in task_ids:
            errors.append(f"duplicate task ID '{task_id}'")
        task_ids.add(task_id)
        task_map[task_id] = task
        for field in ("title", "description"):
            if not isinstance(task.get(field), str) or not task[field].strip():
                errors.append(f"task '{task_id}' field '{field}' is required")
        for field, pattern in (
            ("requirement_refs", REFERENCE_PATTERNS["requirement"]),
            ("acceptance_refs", REFERENCE_PATTERNS["acceptance"]),
        ):
            values = task.get(field)
            if not isinstance(values, list) or not values:
                errors.append(f"task '{task_id}' {field} must be a non-empty array")
                continue
            for reference in values:
                if not isinstance(reference, str) or not pattern.fullmatch(reference):
                    errors.append(
                        f"task '{task_id}' has invalid {field} reference '{reference}'"
                    )
                elif (
                    field == "requirement_refs" and reference not in known_requirements
                ):
                    errors.append(
                        f"task '{task_id}' maps unknown requirement '{reference}'"
                    )
                elif field == "acceptance_refs" and reference not in known_acceptance:
                    errors.append(
                        f"task '{task_id}' maps unknown acceptance criterion '{reference}'"
                    )
            if field == "acceptance_refs":
                all_task_acceptance.update(
                    value for value in values if isinstance(value, str)
                )
        depends_on = task.get("depends_on")
        if not isinstance(depends_on, list) or any(
            not isinstance(value, str) for value in depends_on
        ):
            errors.append(f"task '{task_id}' depends_on must be an array of task IDs")
        planned_files = task.get("planned_files")
        if not isinstance(planned_files, list) or not planned_files:
            errors.append(f"task '{task_id}' planned_files must be a non-empty array")
        else:
            for path in planned_files:
                if not safe_relative_path(path):
                    errors.append(f"task '{task_id}' has unsafe planned file '{path}'")
        verification_tasks = task.get("verification_tasks")
        if not isinstance(verification_tasks, list) or not verification_tasks:
            errors.append(
                f"task '{task_id}' verification_tasks must be a non-empty array"
            )
        else:
            for verification_task in verification_tasks:
                if verification_task not in allowed_verification_tasks:
                    errors.append(
                        f"task '{task_id}' uses unknown verification task '{verification_task}'"
                    )
            verification_set = {
                value for value in verification_tasks if isinstance(value, str)
            }
            if verification_set.intersection({"coverage", "mutation"}) and not (
                verification_set.intersection({"test", "security_tests", "dast"})
            ):
                errors.append(
                    f"task '{task_id}' cannot use coverage or mutation as its only verification; "
                    "map the configured test task or a security test too"
                )
        status = task.get("status")
        if status not in ALLOWED_STATUSES:
            errors.append(
                f"task '{task_id}' status must be one of {sorted(ALLOWED_STATUSES)}"
            )
        if status == "BLOCKED":
            disposition = task.get("blocked_disposition")
            if not isinstance(disposition, dict) or any(
                not str(disposition.get(key, "")).strip()
                for key in (
                    "owner",
                    "rationale",
                    "approver",
                    "approval_id",
                    "timestamp",
                )
            ):
                errors.append(
                    f"blocked task '{task_id}' requires an approved blocked_disposition"
                )
        evidence_entries = task.get("evidence")
        if not isinstance(evidence_entries, list):
            errors.append(f"task '{task_id}' evidence must be an array")
            evidence_entries = []
        expected_commit = arguments.commit_sha or current_commit(root)
        expected_tree = arguments.tree_digest or current_tree_digest(
            root, spec_relative
        )
        if not arguments.ignore_evidence:
            for evidence in evidence_entries:
                validate_evidence(
                    root,
                    feature_id,
                    spec_relative,
                    task_id,
                    evidence,
                    expected_commit,
                    expected_tree,
                    status == "DONE",
                    errors,
                )
                if isinstance(evidence, dict) and evidence.get("result") == "FAIL":
                    errors.append(
                        f"task '{task_id}' failed; requirements={','.join(task.get('requirement_refs', []))}; "
                        f"acceptance={','.join(task.get('acceptance_refs', []))}; "
                        f"files={','.join(task.get('planned_files', []))}; next handoff=Developer fixes the task and reruns its verification"
                    )
        if status == "DONE" and not evidence_entries and not arguments.ignore_evidence:
            errors.append(f"task '{task_id}' cannot be DONE without evidence")
        if "release_blocking" in task and not isinstance(
            task["release_blocking"], bool
        ):
            errors.append(f"task '{task_id}' release_blocking must be boolean")
    for task_id, task in task_map.items():
        for dependency in (
            task.get("depends_on", [])
            if isinstance(task.get("depends_on"), list)
            else []
        ):
            if dependency not in task_ids:
                errors.append(
                    f"task '{task_id}' depends on unknown task '{dependency}'"
                )
    visit_state: dict[str, int] = {}
    cycle_nodes: list[str] = []

    def visit(task_id: str, stack: list[str]) -> None:
        if visit_state.get(task_id) == 1:
            cycle_nodes.extend(stack[stack.index(task_id) :] + [task_id])
            return
        if visit_state.get(task_id) == 2 or task_id not in task_map:
            return
        visit_state[task_id] = 1
        for dependency in (
            task_map[task_id].get("depends_on", [])
            if isinstance(task_map[task_id].get("depends_on"), list)
            else []
        ):
            visit(dependency, stack + [task_id])
        visit_state[task_id] = 2

    for task_id in task_ids:
        visit(task_id, [])
    if cycle_nodes:
        errors.append(
            f"task dependency cycle detected: {' -> '.join(dict.fromkeys(cycle_nodes))}"
        )
    if known_acceptance:
        unmapped = sorted(known_acceptance - all_task_acceptance - manual_acceptance)
        for acceptance_ref in unmapped:
            errors.append(
                f"acceptance criterion '{acceptance_ref}' has no task or manual verification mapping"
            )
    target_phase = arguments.target_phase or ""
    if target_phase == "CODING":
        not_ready = []
        for task_id, task in task_map.items():
            dependencies = (
                task.get("depends_on", [])
                if isinstance(task.get("depends_on"), list)
                else []
            )
            for dependency in dependencies:
                dependency_task = task_map.get(dependency)
                if dependency_task and dependency_task.get("status") not in {
                    "DONE",
                    "BLOCKED",
                }:
                    not_ready.append(f"{task_id} depends on {dependency}")
        if not_ready:
            errors.append(
                f"CODING requires prerequisite tasks DONE or approved BLOCKED: {', '.join(sorted(not_ready))}"
            )
    if target_phase == "REVIEW":
        incomplete = [
            task_id
            for task_id, task in task_map.items()
            if task.get("status") in {"TODO", "IN_PROGRESS"}
        ]
        if incomplete:
            errors.append(
                f"REVIEW requires all coding tasks complete; incomplete tasks: {', '.join(sorted(incomplete))}"
            )
    if target_phase == "DONE":
        incomplete_release = [
            task_id
            for task_id, task in task_map.items()
            if task.get("release_blocking", True) and task.get("status") != "DONE"
        ]
        if incomplete_release:
            errors.append(
                f"DONE requires release-blocking tasks DONE: {', '.join(sorted(incomplete_release))}"
            )
    return document, errors, root, tasks_relative, spec_relative


def record_evidence(arguments: argparse.Namespace) -> int:
    arguments.ignore_evidence = True
    document, errors, root, tasks_relative, _ = validate_graph(arguments)
    if errors:
        for error in errors:
            fail(error)
        return 2
    record_path = Path(arguments.record_path)
    if not record_path.is_absolute():
        record_path = root / record_path
    try:
        record = load_json(record_path)
    except ValueError as error:
        fail(str(error))
        return 2
    task_id = record.get("task") if isinstance(record, dict) else None
    if not isinstance(task_id, str):
        fail("task record must contain a task ID")
        return 2
    target = next(
        (
            task
            for task in document["tasks"]
            if isinstance(task, dict) and task.get("id") == task_id
        ),
        None,
    )
    if target is None:
        fail(f"task record references unknown task '{task_id}'")
        return 2
    evidence_path = repo_relative(root, record_path)
    entry = {
        "task": task_id,
        "command": record.get("command", ""),
        "commit_sha": record.get("commit_sha", ""),
        "tree_digest": record.get("tree_digest", ""),
        "exit_code": record.get("exit_code"),
        "result": record.get("result", ""),
        "evidence": evidence_path,
    }
    existing = [
        item
        for item in target.get("evidence", [])
        if not (
            isinstance(item, dict)
            and item.get("commit_sha") == entry["commit_sha"]
            and item.get("tree_digest") == entry["tree_digest"]
            and item.get("command") == entry["command"]
        )
    ]
    target["evidence"] = existing + [entry]
    tasks_path = root / tasks_relative
    tasks_path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")
    pass_message(f"recorded task evidence for {task_id} in {tasks_relative}")
    return 0


def print_summary(document: dict[str, Any]) -> int:
    tasks = [task for task in document.get("tasks", []) if isinstance(task, dict)]
    counts = {
        status: sum(task.get("status") == status for task in tasks)
        for status in sorted(ALLOWED_STATUSES)
    }
    print("Task Graph Summary")
    print(f"TODO: {counts['TODO']}")
    print(f"IN_PROGRESS: {counts['IN_PROGRESS']}")
    print(f"BLOCKED: {counts['BLOCKED']}")
    print(f"DONE: {counts['DONE']}")
    ready = [
        task["id"]
        for task in tasks
        if task.get("status") == "TODO"
        and all(
            next(
                (candidate for candidate in tasks if candidate.get("id") == dependency),
                {},
            ).get("status")
            in {"DONE", "BLOCKED"}
            for dependency in task.get("depends_on", [])
        )
    ]
    if ready:
        print(f"READY: {', '.join(sorted(ready))}")
    return 0


def print_scope(arguments: argparse.Namespace) -> int:
    document, errors, root, _, spec_relative = validate_graph(arguments)
    if errors:
        for error in errors:
            fail(error)
        return 2
    planned: set[str] = set()
    for task in document.get("tasks", []):
        if isinstance(task, dict):
            planned.update(
                normalize_path(path) for path in task.get("planned_files", [])
            )
    shared = []
    for record in front_matter_list(root / spec_relative, "approved_shared_files"):
        path = normalize_path(record.split("|", 1)[0])
        if path:
            shared.append(path)
    scope = {
        "feature_id": arguments.feature_id or "",
        "spec_path": spec_relative,
        "planned_files": sorted(planned),
        "approved_shared_files": sorted(set(shared)),
    }
    if arguments.output_format == "lines":
        print(f"SPEC_PATH:{scope['spec_path']}")
        for path in scope["planned_files"]:
            print(f"TASK_FILE:{path}")
        for path in scope["approved_shared_files"]:
            print(f"SHARED_FILE:{path}")
    else:
        print(json.dumps(scope))
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "command", choices=("validate", "record-evidence", "summary", "scope")
    )
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--feature-id", default="")
    parser.add_argument("--tasks-path", default="")
    parser.add_argument("--spec-path", default="")
    parser.add_argument("--config-path", default="")
    parser.add_argument("--record-path", default="")
    parser.add_argument("--commit-sha", default="")
    parser.add_argument("--tree-digest", default="")
    parser.add_argument("--target-phase", default="")
    parser.add_argument("--output-format", choices=("json", "lines"), default="json")
    arguments = parser.parse_args()
    arguments.ignore_evidence = False
    try:
        if arguments.command == "record-evidence":
            if not arguments.record_path:
                fail("record-evidence requires --record-path")
                return 2
            return record_evidence(arguments)
        if arguments.command == "scope":
            return print_scope(arguments)
        document, errors, _, _, _ = validate_graph(arguments)
        if errors:
            for error in errors:
                fail(error)
            return 2
        if arguments.command == "summary":
            return print_summary(document)
        pass_message(
            "task graph schema, mappings, dependencies, scope paths, and evidence are valid"
        )
        return 0
    except (OSError, ValueError) as error:
        fail(str(error))
        return 2


if __name__ == "__main__":
    sys.exit(main())
