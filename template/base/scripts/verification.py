#!/usr/bin/env python3
"""Validate revision-bound coverage and mutation reports."""

from __future__ import annotations

import argparse
import fnmatch
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

SUPPORTED_COVERAGE_PROVIDERS = {"coverage-py-json", "generic-json"}
SUPPORTED_MUTATION_PROVIDERS = {"generic-json"}
HUNK_PATTERN = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@")
EXECUTABLE_SUFFIXES = {
    ".c",
    ".cc",
    ".cpp",
    ".cs",
    ".go",
    ".h",
    ".java",
    ".js",
    ".jsx",
    ".kt",
    ".m",
    ".php",
    ".py",
    ".rb",
    ".rs",
    ".scala",
    ".sh",
    ".sql",
    ".swift",
    ".ts",
    ".tsx",
    ".vue",
}


def normalize_path(value: str) -> str:
    normalized = str(value).strip().replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def safe_relative_path(value: str) -> bool:
    normalized = normalize_path(value)
    return bool(
        normalized
        and not normalized.startswith("/")
        and not re.match(r"^[A-Za-z]:/", normalized)
        and not re.search(r"(^|/)\.\.(?:/|$)", normalized)
    )


def resolve_relative(root: Path, value: str) -> Path:
    if not safe_relative_path(value):
        raise ValueError(f"path must be safe and repository-relative: {value}")
    candidate = (root / normalize_path(value)).resolve()
    try:
        candidate.relative_to(root.resolve())
    except ValueError as error:
        raise ValueError(f"path escapes repository root: {value}") from error
    return candidate


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
    return result.stdout


def current_commit(root: Path) -> str:
    return run_git(root, "rev-parse", "HEAD").strip()


def tree_digest(root: Path, spec_path: str) -> str:
    commit = current_commit(root)
    if not commit:
        return ""
    diff = run_git(
        root,
        "diff",
        "--binary",
        "HEAD",
        "--",
        ".",
        f":(exclude){spec_path}",
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
    return hashlib.sha256("\n".join(sorted(parts)).encode("utf-8")).hexdigest()


def report_revision(report: dict[str, Any]) -> tuple[str, str]:
    metadata = report.get("meta")
    if not isinstance(metadata, dict):
        metadata = {}
    commit = ""
    for key in ("commit_sha", "source_revision", "revision"):
        value = report.get(key, metadata.get(key, ""))
        if value:
            commit = str(value)
            break
    tree = ""
    for key in ("tree_digest", "working_tree_digest", "source_tree_digest"):
        value = report.get(key, metadata.get(key, ""))
        if value:
            tree = str(value)
            break
    return commit, tree


def validate_report_revision(
    report: dict[str, Any], expected_commit: str, expected_tree: str
) -> None:
    report_commit, report_tree = report_revision(report)
    if not report_commit or not report_tree:
        raise ValueError(
            "verification report must include commit_sha and tree_digest metadata"
        )
    if expected_commit and report_commit != expected_commit:
        raise ValueError(
            f"verification report commit_sha '{report_commit}' is stale; expected '{expected_commit}'"
        )
    if expected_tree and report_tree != expected_tree:
        raise ValueError(
            "verification report tree_digest is stale for the current working tree"
        )


def path_matches_exclusion(path: str, patterns: list[str]) -> bool:
    normalized = normalize_path(path)
    for pattern in patterns:
        normalized_pattern = normalize_path(pattern)
        if fnmatch.fnmatchcase(normalized, normalized_pattern):
            return True
        if normalized_pattern.endswith("/**") and normalized.startswith(
            normalized_pattern[:-3].rstrip("/") + "/"
        ):
            return True
    return False


def is_probably_executable(path: str) -> bool:
    return Path(path).suffix.lower() in EXECUTABLE_SUFFIXES


def parse_changed_lines(
    root: Path, excluded_paths: list[str]
) -> tuple[dict[str, set[int] | None], set[str]]:
    changed: dict[str, set[int] | None] = {}
    diff = run_git(root, "diff", "--unified=0", "--no-color", "HEAD", "--", ".")
    current_file = ""
    new_line: int | None = None
    for raw_line in diff.splitlines():
        if raw_line.startswith("+++ b/"):
            if raw_line[6:] == "/dev/null":
                current_file = ""
                continue
            current_file = normalize_path(raw_line[6:])
            if (
                current_file == ".sdlc"
                or current_file.startswith(".sdlc/")
                or path_matches_exclusion(current_file, excluded_paths)
            ):
                current_file = ""
            else:
                changed.setdefault(current_file, set())
            continue
        hunk = HUNK_PATTERN.match(raw_line)
        if hunk:
            new_line = int(hunk.group(1))
            continue
        if (
            not current_file
            or new_line is None
            or raw_line.startswith(("--- ", "diff ", "index "))
        ):
            continue
        if raw_line.startswith("+"):
            changed[current_file].add(new_line)
            new_line += 1
        elif raw_line.startswith("-"):
            continue
        else:
            new_line += 1

    untracked_files: set[str] = set()
    untracked = run_git(root, "ls-files", "--others", "--exclude-standard")
    for raw_path in untracked.splitlines():
        relative = normalize_path(raw_path)
        if (
            not relative
            or relative == ".sdlc"
            or relative.startswith(".sdlc/")
            or path_matches_exclusion(relative, excluded_paths)
        ):
            continue
        path = root / relative
        if path.is_file():
            changed.setdefault(relative, None)
            untracked_files.add(relative)
    changed.pop("", None)
    return changed, untracked_files


def normalize_report_path(root: Path, value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("verification report file paths must be non-empty strings")
    raw = normalize_path(value)
    root_text = normalize_path(str(root.resolve()))
    if raw.lower().startswith(root_text.lower().rstrip("/") + "/"):
        raw = raw[len(root_text.rstrip("/")) + 1 :]
    if not safe_relative_path(raw):
        raise ValueError(f"verification report contains an unsafe file path: {value}")
    return raw


def line_numbers(value: Any) -> set[int]:
    if isinstance(value, dict):
        values = [key for key, present in value.items() if present]
    elif isinstance(value, list):
        values = value
    else:
        return set()
    result: set[int] = set()
    for item in values:
        try:
            number = int(item)
        except (TypeError, ValueError):
            continue
        if number > 0:
            result.add(number)
    return result


def first_line_set(data: dict[str, Any], keys: tuple[str, ...]) -> tuple[set[int], str]:
    for key in keys:
        if key in data:
            return line_numbers(data[key]), key
    return set(), ""


def coverage_file_lines(data: Any) -> tuple[set[int], set[int], set[int]]:
    if not isinstance(data, dict):
        raise ValueError("coverage report file entries must be objects")
    covered, covered_key = first_line_set(data, ("executed_lines", "covered_lines"))
    missing, missing_key = first_line_set(data, ("missing_lines", "uncovered_lines"))
    excluded, _ = first_line_set(data, ("excluded_lines",))
    if not covered_key and not missing_key and isinstance(data.get("lines"), dict):
        line_map = data["lines"]
        covered = line_numbers({key: value for key, value in line_map.items() if value})
        missing = line_numbers(
            {key: value for key, value in line_map.items() if not value}
        )
    if not covered_key and not missing_key and not isinstance(data.get("lines"), dict):
        raise ValueError(
            "coverage report file entries must include executable line arrays"
        )
    executable = (covered | missing) - excluded
    return executable, covered - excluded, excluded


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        raise ValueError(f"verification report not found: {path}") from error
    except json.JSONDecodeError as error:
        raise ValueError(f"invalid verification report JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("verification report root must be an object")
    return value


def coverage_record(
    root: Path,
    report_path: str,
    provider: str,
    threshold: float,
    excluded_paths: list[str],
    expected_commit: str,
    expected_tree: str,
) -> dict[str, Any]:
    if provider not in SUPPORTED_COVERAGE_PROVIDERS:
        raise ValueError(f"unsupported coverage provider '{provider}'")
    report_file = resolve_relative(root, report_path)
    report = load_json(report_file)
    validate_report_revision(report, expected_commit, expected_tree)
    raw_files = report.get("files")
    if not isinstance(raw_files, dict):
        raise ValueError("coverage report must contain a files object")

    coverage: dict[str, tuple[set[int], set[int], set[int]]] = {}
    excluded_files: list[str] = []
    for raw_path, file_data in raw_files.items():
        path = normalize_report_path(root, raw_path)
        if path_matches_exclusion(path, excluded_paths):
            excluded_files.append(path)
            continue
        coverage[path] = coverage_file_lines(file_data)

    changed, untracked = parse_changed_lines(root, excluded_paths)
    changed_executable: set[tuple[str, int]] = set()
    covered_changed: set[tuple[str, int]] = set()
    unreported: list[str] = []
    for path, changed_lines in changed.items():
        if path not in coverage:
            if not is_probably_executable(path):
                continue
            unreported.append(path)
            continue
        executable, covered, _ = coverage[path]
        candidate_lines = (
            executable if path in untracked else (changed_lines or set()) & executable
        )
        for line in candidate_lines:
            changed_executable.add((path, line))
            if line in covered:
                covered_changed.add((path, line))

    total = len(changed_executable)
    covered_count = len(covered_changed)
    percentage = (covered_count / total * 100) if total else None
    errors = []
    if unreported:
        errors.append(
            "coverage report has no entry for changed executable file(s): "
            + ", ".join(sorted(unreported))
        )
    result = (
        "FAIL"
        if errors
        else (
            "NOT_APPLICABLE"
            if total == 0
            else ("PASS" if percentage >= threshold else "FAIL")
        )
    )
    return {
        "schema": 1,
        "kind": "coverage-verification",
        "provider": provider,
        "report_path": normalize_path(report_path),
        "report_sha256": hashlib.sha256(report_file.read_bytes()).hexdigest(),
        "commit_sha": expected_commit,
        "tree_digest": expected_tree,
        "changed_files": sorted(changed),
        "unreported_changed_files": sorted(unreported),
        "changed_executable_lines": [
            {"file": path, "line": line} for path, line in sorted(changed_executable)
        ],
        "covered_lines": [
            {"file": path, "line": line} for path, line in sorted(covered_changed)
        ],
        "total_changed_lines": total,
        "covered_changed_lines": covered_count,
        "percentage": percentage,
        "threshold": threshold,
        "excluded_paths": excluded_paths,
        "excluded_files": sorted(excluded_files),
        "errors": errors,
        "result": result,
        "exit_code": 0 if result != "FAIL" else 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def mutation_revision_and_tool(report: dict[str, Any]) -> tuple[str, str]:
    tool = report.get("tool")
    if isinstance(tool, dict):
        return str(tool.get("name", "")), str(tool.get("version", ""))
    return str(tool or ""), str(report.get("tool_version", ""))


def mutation_record(
    root: Path,
    report_path: str,
    provider: str,
    threshold: float,
    excluded_paths: list[str],
    expected_commit: str,
    expected_tree: str,
) -> dict[str, Any]:
    if provider not in SUPPORTED_MUTATION_PROVIDERS:
        raise ValueError(f"unsupported mutation provider '{provider}'")
    report_file = resolve_relative(root, report_path)
    report = load_json(report_file)
    validate_report_revision(report, expected_commit, expected_tree)
    tool_name, tool_version = mutation_revision_and_tool(report)
    if not tool_name or not tool_version:
        raise ValueError("mutation report must include tool name and tool_version")

    raw_mutants = report.get("mutants")
    excluded: list[dict[str, Any]] = []
    survivors: list[dict[str, Any]] = []
    killed = 0
    if isinstance(raw_mutants, list):
        for index, raw_mutant in enumerate(raw_mutants):
            if not isinstance(raw_mutant, dict):
                raise ValueError("mutation report mutants must be objects")
            path = normalize_report_path(root, raw_mutant.get("file", ""))
            status = str(raw_mutant.get("status", "")).lower()
            item = {
                "id": str(raw_mutant.get("id", index + 1)),
                "file": path,
                "line": raw_mutant.get("line"),
                "status": status,
            }
            if path_matches_exclusion(path, excluded_paths) or status in {
                "excluded",
                "skipped",
                "equivalent",
            }:
                excluded.append(item)
            elif status == "killed":
                killed += 1
            else:
                item["disposition"] = str(raw_mutant.get("disposition", "")).strip()
                survivors.append(item)
    else:
        summary = report.get("summary")
        if not isinstance(summary, dict):
            raise ValueError("mutation report must contain mutants or a summary object")
        try:
            killed = int(summary.get("killed", 0))
            survivor_count = int(summary.get("survived", summary.get("survivors", 0)))
            excluded_count = int(summary.get("excluded", 0))
        except (TypeError, ValueError) as error:
            raise ValueError("mutation summary counts must be integers") from error
        dispositions = report.get(
            "survivor_dispositions", report.get("survivor_disposition", "")
        )
        if isinstance(dispositions, list):
            for index, disposition in enumerate(dispositions):
                survivors.append(
                    {"id": str(index + 1), "disposition": str(disposition).strip()}
                )
        else:
            for index in range(survivor_count):
                survivors.append(
                    {"id": str(index + 1), "disposition": str(dispositions).strip()}
                )
        excluded = [{"id": str(index + 1)} for index in range(excluded_count)]

    missing_dispositions = [
        item["id"] for item in survivors if not item.get("disposition")
    ]
    if missing_dispositions:
        disposition_error = "surviving mutants require a disposition: " + ", ".join(
            missing_dispositions
        )
    else:
        disposition_error = ""
    active_count = killed + len(survivors)
    score = (killed / active_count * 100) if active_count else None
    result = (
        "NOT_APPLICABLE"
        if active_count == 0
        else ("PASS" if score >= threshold else "FAIL")
    )
    errors = []
    if disposition_error:
        errors.append(disposition_error)
        result = "FAIL"
    if result == "FAIL" and score is not None and score < threshold:
        errors.append(f"mutation score {score:.2f} is below threshold {threshold:.2f}")
    return {
        "schema": 1,
        "kind": "mutation-verification",
        "provider": provider,
        "report_path": normalize_path(report_path),
        "report_sha256": hashlib.sha256(report_file.read_bytes()).hexdigest(),
        "commit_sha": expected_commit,
        "tree_digest": expected_tree,
        "tool": tool_name,
        "tool_version": tool_version,
        "mutation_count": active_count + len(excluded),
        "active_mutation_count": active_count,
        "killed": killed,
        "survived": len(survivors),
        "excluded_count": len(excluded),
        "mutation_score": score,
        "threshold": threshold,
        "excluded_paths": excluded_paths,
        "excluded_mutants": excluded,
        "survivors": survivors,
        "errors": errors,
        "result": result,
        "exit_code": 0 if result != "FAIL" else 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    }


def write_record(path: Path, record: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")


def validate_record(
    root: Path,
    kind: str,
    record_path: str,
    expected_commit: str,
    expected_tree: str,
) -> None:
    record_file = resolve_relative(root, record_path)
    record = load_json(record_file)
    expected_kind = f"{kind}-verification"
    if record.get("kind") != expected_kind:
        raise ValueError(f"verification evidence kind must be '{expected_kind}'")
    if record.get("commit_sha") != expected_commit:
        raise ValueError("verification evidence commit_sha is stale")
    if record.get("tree_digest") != expected_tree:
        raise ValueError("verification evidence tree_digest is stale")
    report_path = record.get("report_path")
    provider = record.get("provider")
    threshold = record.get("threshold")
    excluded_paths = record.get("excluded_paths", [])
    if (
        not isinstance(report_path, str)
        or not isinstance(provider, str)
        or not isinstance(threshold, (int, float))
        or not isinstance(excluded_paths, list)
        or any(not isinstance(path, str) for path in excluded_paths)
    ):
        raise ValueError("verification evidence is missing its report policy fields")
    if kind == "coverage":
        recomputed = coverage_record(
            root,
            report_path,
            provider,
            float(threshold),
            excluded_paths,
            expected_commit,
            expected_tree,
        )
    elif kind == "mutation":
        recomputed = mutation_record(
            root,
            report_path,
            provider,
            float(threshold),
            excluded_paths,
            expected_commit,
            expected_tree,
        )
    else:
        raise ValueError(f"unsupported verification evidence kind '{kind}'")
    fields = [
        "report_sha256",
        "result",
        "exit_code",
        "threshold",
        "commit_sha",
        "tree_digest",
    ]
    if kind == "coverage":
        fields.extend(
            (
                "total_changed_lines",
                "covered_changed_lines",
                "percentage",
                "unreported_changed_files",
            )
        )
    else:
        fields.extend(
            (
                "mutation_score",
                "active_mutation_count",
                "killed",
                "survived",
                "excluded_count",
            )
        )
    for field in fields:
        if record.get(field) != recomputed.get(field):
            raise ValueError(
                f"verification evidence field '{field}' does not match the current report"
            )
    if record.get("result") not in {"PASS", "NOT_APPLICABLE"}:
        raise ValueError("verification evidence result must be PASS or NOT_APPLICABLE")
    if record.get("exit_code") != 0:
        raise ValueError("passing verification evidence must have exit_code 0")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=("coverage", "mutation", "validate-record"))
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--report-path", default="")
    parser.add_argument("--provider", default="")
    parser.add_argument("--threshold", default=None, type=float)
    parser.add_argument("--exclude", action="append", default=[])
    parser.add_argument("--commit-sha", default="")
    parser.add_argument("--tree-digest", default="")
    parser.add_argument("--output-path", default="")
    parser.add_argument("--record-kind", choices=("coverage", "mutation"), default="")
    parser.add_argument("--record-path", default="")
    arguments = parser.parse_args()
    root = Path(arguments.repo_root).resolve()
    commit = arguments.commit_sha or current_commit(root)
    tree = arguments.tree_digest or tree_digest(root, "docs/spec.md")
    output_path: Path | None = None
    try:
        if arguments.kind == "validate-record":
            if not arguments.record_kind or not arguments.record_path:
                raise ValueError(
                    "validate-record requires --record-kind and --record-path"
                )
            validate_record(
                root,
                arguments.record_kind,
                arguments.record_path,
                commit,
                tree,
            )
            print(
                "[PASS] Verification evidence matches the current report and revision."
            )
            return 0
        if (
            not arguments.report_path
            or not arguments.provider
            or arguments.threshold is None
            or not arguments.output_path
        ):
            raise ValueError(
                "coverage or mutation requires --report-path, --provider, --threshold, and --output-path"
            )
        output_path = resolve_relative(root, arguments.output_path)
        if arguments.kind == "coverage":
            record = coverage_record(
                root,
                arguments.report_path,
                arguments.provider,
                arguments.threshold,
                arguments.exclude,
                commit,
                tree,
            )
        else:
            record = mutation_record(
                root,
                arguments.report_path,
                arguments.provider,
                arguments.threshold,
                arguments.exclude,
                commit,
                tree,
            )
    except (OSError, ValueError) as error:
        if arguments.kind == "validate-record" or output_path is None:
            print(f"[FAIL] {error}")
            return 1
        record = {
            "schema": 1,
            "kind": f"{arguments.kind}-verification",
            "provider": arguments.provider,
            "report_path": normalize_path(arguments.report_path),
            "commit_sha": commit,
            "tree_digest": tree,
            "threshold": arguments.threshold,
            "excluded_paths": arguments.exclude,
            "errors": [str(error)],
            "result": "FAIL",
            "exit_code": 1,
            "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        }
        write_record(output_path, record)
        print(f"[FAIL] {error}")
        print(f"[INFO] Verification evidence: {output_path}")
        return 1
    write_record(output_path, record)
    if record["result"] == "PASS":
        print(
            f"[PASS] {arguments.kind} verification: {record.get('percentage', record.get('mutation_score'))}"
        )
    elif record["result"] == "NOT_APPLICABLE":
        print(f"[PASS] {arguments.kind} verification: NOT_APPLICABLE")
    else:
        for error in record.get("errors", []):
            print(f"[FAIL] {error}")
        print(f"[FAIL] {arguments.kind} verification result is {record['result']}")
    print(f"[INFO] Verification evidence: {output_path}")
    return int(record["exit_code"])


if __name__ == "__main__":
    sys.exit(main())
