#!/usr/bin/env python3
"""Portable distribution and upgrade CLI for the Copilot SDLC template."""

from __future__ import annotations

import argparse
import datetime as dt
import difflib
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import uuid
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

CLI_VERSION = "1.0.0"
STATE_RELATIVE = ".sdlc/sdlc-installer-state.json"
PROJECT_OWNED = {".github/sdlc-config.yml", "docs/spec.md"}
REQUIRED_STATE_FIELDS = (
    "templateVersion",
    "extensionVersions",
    "manifestSha256",
    "sourceRevision",
    "platform",
)


class SdlcError(Exception):
    pass


def utc_now() -> str:
    return (
        dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def script_root() -> Path:
    path = Path(__file__).resolve()
    if (
        path.parent.name.lower() == "scripts"
        and path.parent.parent.name.lower() == "base"
    ):
        return path.parents[3]
    return path.parent.parent


def normalize_rel(value: str) -> str:
    normalized = value.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized.lstrip("/")


def assert_safe_rel(value: str) -> str:
    normalized = normalize_rel(value)
    path = PurePosixPath(normalized)
    if not normalized or path.is_absolute() or ".." in path.parts:
        raise SdlcError(f"Path must be relative to the target: {value}")
    return normalized


def is_project_owned(relative: str) -> bool:
    return relative in PROJECT_OWNED


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def json_write(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(
        json.dumps(value, indent=2, sort_keys=False) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    temporary.replace(path)


def parse_scalar(value: str) -> Any:
    value = value.strip()
    if not value:
        return ""
    if value.startswith("[") and value.endswith("]"):
        body = value[1:-1].strip()
        if not body:
            return []
        return [parse_scalar(item) for item in body.split(",") if item.strip()]
    if (value.startswith('"') and value.endswith('"')) or (
        value.startswith("'") and value.endswith("'")
    ):
        return value[1:-1]
    if value.lower() == "true":
        return True
    if value.lower() == "false":
        return False
    return value


def read_manifest(path: Path) -> dict[str, Any]:
    if not path.is_file():
        raise SdlcError(f"Template manifest not found: {path}")

    manifest: dict[str, Any] = {"base_installs": [], "extensions": {}}
    lines = path.read_text(encoding="utf-8").replace("\r", "").splitlines()
    section = ""
    current_extension: str | None = None
    collecting_base = False
    base_indent = -1
    for raw in lines:
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        trimmed = raw.strip()
        if indent == 0:
            collecting_base = False
            current_extension = None
            if trimmed == "template:":
                section = "template"
            elif trimmed == "base:":
                section = "base"
            elif trimmed == "extensions:":
                section = "extensions"
            else:
                section = ""
            continue
        if section == "template" and indent == 2 and trimmed.startswith("version:"):
            manifest["version"] = str(parse_scalar(trimmed.split(":", 1)[1]))
            continue
        if section == "template" and indent == 2 and trimmed.startswith("name:"):
            manifest["name"] = str(parse_scalar(trimmed.split(":", 1)[1]))
            continue
        if (
            section == "template"
            and indent == 2
            and trimmed.startswith("supported_installers:")
        ):
            manifest["supported_installers"] = parse_scalar(trimmed.split(":", 1)[1])
            continue
        if section == "base":
            if indent == 2 and trimmed == "installs:":
                collecting_base = True
                base_indent = indent
                continue
            if collecting_base:
                if indent > base_indent and trimmed.startswith("-"):
                    manifest["base_installs"].append(
                        str(parse_scalar(trimmed[1:].strip()))
                    )
                    continue
                collecting_base = False
        if section == "extensions":
            if indent == 2 and trimmed.endswith(":"):
                current_extension = trimmed[:-1]
                manifest["extensions"][current_extension] = {}
                continue
            if current_extension and indent >= 4 and ":" in trimmed:
                key, value = trimmed.split(":", 1)
                manifest["extensions"][current_extension][key.strip()] = parse_scalar(
                    value
                )

    if not manifest.get("version"):
        raise SdlcError(f"Template version is missing from {path}")
    if not manifest.get("base_installs"):
        raise SdlcError(f"Template manifest lists no base.installs entries: {path}")
    manifest["manifest_sha256"] = sha256_file(path)
    return manifest


def covered(entry: str, output: str) -> bool:
    normalized = normalize_rel(str(entry))
    if normalized.endswith("/"):
        return output.startswith(normalized)
    return output == normalized


def template_output(source_file: Path, root: Path) -> tuple[str, bool]:
    relative = source_file.relative_to(root).as_posix()
    if relative.endswith(".template"):
        return relative[:-9], True
    if relative.endswith(".tmpl"):
        return relative[:-5], True
    return relative, False


def collect_layer(
    root: Path, layer: str, extension: str | None = None
) -> list[dict[str, Any]]:
    if not root.is_dir():
        raise SdlcError(f"Template layer not found: {root}")
    entries: list[dict[str, Any]] = []
    for source in sorted(root.rglob("*"), key=lambda item: item.as_posix()):
        if (
            not source.is_file()
            or ".git" in source.parts
            or "__pycache__" in source.parts
            or source.suffix == ".pyc"
        ):
            continue
        output, render = template_output(source, root)
        output = assert_safe_rel(output)
        entries.append(
            {
                "output": output,
                "source": source,
                "render": render,
                "layer": layer,
                "extension": extension,
            }
        )
    return entries


def resolve_extension(
    source_root: Path, name: str, metadata: dict[str, Any]
) -> tuple[Path, str]:
    if not name:
        raise SdlcError("Extension names cannot be empty.")
    path_candidate = Path(name)
    if path_candidate.is_absolute() or "/" in name or "\\" in name:
        if ".." in path_candidate.parts:
            raise SdlcError(f"Extension path traversal is not allowed: {name}")
        if not path_candidate.is_dir():
            raise SdlcError(f"Extension path not found: {name}")
        return path_candidate.resolve(), "unknown"
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise SdlcError(f"Invalid extension name: {name}")
    root = source_root / "template" / "extensions" / name
    if not root.is_dir():
        raise SdlcError(f"Extension '{name}' was not found: {root}")
    extension_info = metadata.get(name, {})
    return root, str(extension_info.get("version", "unknown"))


def contract_hash(source_root: Path) -> str:
    contract = source_root / "template" / "base" / "docs" / "portable-agent-contract.md"
    if not contract.is_file():
        raise SdlcError(f"Portable agent contract not found: {contract}")
    return sha256_file(contract)


def adapter_template_hash(source_root: Path) -> str:
    template = (
        source_root
        / "template"
        / "base"
        / ".github"
        / "copilot-instructions.md.template"
    )
    if not template.is_file():
        return ""
    content = (
        template.read_text(encoding="utf-8").replace("\r\n", "\n").replace("\r", "\n")
    )
    return sha256_bytes(content.encode("utf-8"))


def render_entry(entry: dict[str, Any], tokens: dict[str, str]) -> bytes:
    if "data" in entry:
        return bytes(entry["data"])
    data = Path(entry["source"]).read_bytes()
    if not entry.get("render"):
        return data
    text = data.decode("utf-8")
    for name, value in tokens.items():
        text = text.replace("{{" + name + "}}", value)
    return text.encode("utf-8")


def build_plan(
    source_root: Path, target: Path, extensions: list[str], surface: str
) -> dict[str, Any]:
    manifest = read_manifest(source_root / "template" / "manifest.yml")
    template_root = source_root / "template" / "base"
    base_entries = collect_layer(template_root, "base")
    base_outputs = [entry["output"] for entry in base_entries]
    missing = [
        output
        for output in base_outputs
        if not any(covered(item, output) for item in manifest["base_installs"])
    ]
    unmatched = [
        item
        for item in manifest["base_installs"]
        if not any(covered(item, output) for output in base_outputs)
    ]
    if missing or unmatched:
        details = []
        if missing:
            details.append(
                "base files missing from the manifest: " + ", ".join(missing)
            )
        if unmatched:
            details.append(
                "manifest entries with no matching base file: "
                + ", ".join(map(str, unmatched))
            )
        raise SdlcError(
            "template/manifest.yml is out of sync with template/base ("
            + "; ".join(details)
            + ")"
        )

    entries: dict[str, dict[str, Any]] = {}
    order: list[str] = []
    for entry in base_entries:
        if entry["output"] not in entries:
            order.append(entry["output"])
        entries[entry["output"]] = entry

    extension_versions: dict[str, str] = {}
    extension_files: dict[str, list[str]] = {}
    for extension in extensions:
        extension_root, version = resolve_extension(
            source_root, extension, manifest.get("extensions", {})
        )
        extension_versions[extension] = version
        for entry in collect_layer(extension_root, f"extension:{extension}", extension):
            if entry["output"] not in entries:
                order.append(entry["output"])
            entries[entry["output"]] = entry
            extension_files.setdefault(extension, []).append(entry["output"])

    if surface not in {"copilot", "generic", "all"}:
        raise SdlcError(f"Unsupported agent surface: {surface}")
    if surface in {"generic", "all"}:
        contract = (
            source_root / "template" / "base" / "docs" / "portable-agent-contract.md"
        )
        generated = (
            "<!-- GENERATED FILE: do not edit directly. -->\n"
            "<!-- SDLC_PORTABLE_CONTRACT: generic -->\n"
            "<!-- portable-contract: docs/portable-agent-contract.md -->\n"
            f"<!-- portable-contract-sha256: {sha256_file(contract)} -->\n"
            f"<!-- template-version: {manifest['version']} -->\n\n"
            + contract.read_text(encoding="utf-8")
            .replace("\r\n", "\n")
            .replace("\r", "\n")
        ).encode("utf-8")
        generated_entry = {
            "output": "AGENTS.md",
            "data": generated,
            "render": False,
            "layer": "generated:generic",
            "extension": None,
        }
        if "AGENTS.md" not in entries:
            order.append("AGENTS.md")
        entries["AGENTS.md"] = generated_entry

    tokens = {
        "ProjectName": target.name,
        "ProjectRoot": str(target),
        "Template": "base",
        "TemplateVersion": str(manifest["version"]),
        "PortableContractHash": contract_hash(source_root),
        "CopilotAdapterTemplateHash": adapter_template_hash(source_root),
        "PROJECT_NAME": target.name,
        "PROJECT_ROOT": str(target),
    }
    plan_entries = {relative: entries[relative] for relative in order}
    return {
        "manifest": manifest,
        "entries": plan_entries,
        "order": order,
        "extension_versions": extension_versions,
        "extension_files": extension_files,
        "tokens": tokens,
        "surface": surface,
    }


def state_path(target: Path) -> Path:
    return target / STATE_RELATIVE


def load_state(target: Path, allow_missing: bool = True) -> dict[str, Any]:
    path = state_path(target)
    if not path.exists():
        if allow_missing:
            return {}
        raise SdlcError(f"Installer state is missing: {path}")
    if not path.is_file():
        raise SdlcError(f"Installer state path is not a file: {path}")
    try:
        state = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SdlcError(f"Could not read installer state '{path}': {exc}") from exc
    if not isinstance(state, dict) or state.get("installer") != "Copilot-SDLC-Demo":
        raise SdlcError(f"Unrecognized installer state: {path}")
    if state.get("schemaVersion") not in (1, 2):
        raise SdlcError(f"Unsupported installer state schema: {path}")
    return state


def managed_hashes(state: dict[str, Any]) -> dict[str, str]:
    result: dict[str, str] = {}
    for record in state.get("files", []):
        if not isinstance(record, dict):
            continue
        relative = assert_safe_rel(str(record.get("path", "")))
        digest = str(record.get("hash", "")).lower()
        if relative != STATE_RELATIVE and digest:
            result[relative] = digest
    return result


def effective_extensions(
    args: argparse.Namespace, state: dict[str, Any], command: str
) -> tuple[list[str], list[str]]:
    previous = [str(item) for item in state.get("extensions", [])]
    requested = args.extensions
    if requested is None:
        selected = previous if command in {"init", "update", "diff", "doctor"} else []
    else:
        selected = list(requested)
    removals = list(args.remove_extension or [])
    selected = [item for item in selected if item not in removals]
    deduplicated: list[str] = []
    for item in selected:
        if item not in deduplicated:
            deduplicated.append(item)
    return deduplicated, removals


def effective_surface(
    args: argparse.Namespace, state: dict[str, Any], command: str
) -> str:
    if args.agent_surface:
        return args.agent_surface
    if command in {"update", "diff", "doctor"}:
        return str(state.get("agentSurface", "copilot"))
    return "copilot"


def compute_plan_diff(
    target: Path,
    source_root: Path,
    extensions: list[str],
    removed_extensions: list[str],
    surface: str,
) -> dict[str, Any]:
    state = load_state(target)
    plan = build_plan(source_root, target, extensions, surface)
    previous_hashes = managed_hashes(state)
    operations: list[dict[str, Any]] = []
    candidates: dict[str, bytes] = {}
    for relative in plan["order"]:
        entry = plan["entries"][relative]
        candidate = render_entry(entry, plan["tokens"])
        candidates[relative] = candidate
        destination = target / Path(relative)
        if is_project_owned(relative):
            action = (
                "project-owned" if destination.exists() else "add-project-owned-default"
            )
        elif not destination.exists():
            action = "add"
        elif destination.read_bytes() == candidate:
            action = "keep"
        elif relative not in previous_hashes:
            action = "conflict-unmanaged"
        elif sha256_file(destination) != previous_hashes[relative]:
            action = "conflict-modified"
        else:
            action = "update"
        operations.append({"path": relative, "action": action})

    old_extension_files = state.get("extensionFiles", {})
    removed_paths: list[str] = []
    selected_set = set(extensions)
    for extension in removed_extensions:
        for relative in (
            old_extension_files.get(extension, [])
            if isinstance(old_extension_files, dict)
            else []
        ):
            relative = assert_safe_rel(str(relative))
            if relative in selected_set or relative in plan["entries"]:
                continue
            destination = target / Path(relative)
            if not destination.exists():
                action = "remove-missing"
            elif is_project_owned(relative):
                action = "preserve-project-owned"
            elif (
                relative not in previous_hashes
                or sha256_file(destination) != previous_hashes[relative]
            ):
                action = "conflict-removal"
            else:
                action = "remove"
                removed_paths.append(relative)
            operations.append(
                {"path": relative, "action": action, "extension": extension}
            )

    return {
        "state": state,
        "plan": plan,
        "operations": operations,
        "candidates": candidates,
        "removed_paths": removed_paths,
        "source_root": str(source_root),
        "target": str(target),
        "extensions": extensions,
        "surface": surface,
    }


def print_diff(result: dict[str, Any], as_json: bool = False) -> None:
    operations = result["operations"]
    if as_json:
        payload = {
            "schema": 1,
            "kind": "sdlc-installer-plan",
            "target": result["target"],
            "source": result["source_root"],
            "templateVersion": result["plan"]["manifest"]["version"],
            "extensions": result["extensions"],
            "agentSurface": result["surface"],
            "operations": operations,
        }
        print(json.dumps(payload, indent=2))
        return
    print(f"SDLC installer plan for {result['target']}")
    print(f"Template version: {result['plan']['manifest']['version']}")
    for operation in operations:
        print(f"[{operation['action'].upper()}] {operation['path']}")
        if operation["action"] not in {"update", "conflict-modified"}:
            continue
        relative = operation["path"]
        destination = Path(result["target"]) / Path(relative)
        candidate = result["candidates"].get(relative, b"")
        try:
            current_lines = (
                destination.read_text(encoding="utf-8").splitlines(keepends=True)
                if destination.exists()
                else []
            )
            candidate_lines = candidate.decode("utf-8").splitlines(keepends=True)
            diff = difflib.unified_diff(
                current_lines,
                candidate_lines,
                fromfile=relative,
                tofile=f"{relative} (candidate)",
            )
            sys.stdout.writelines(diff)
        except (OSError, UnicodeDecodeError):
            print("  binary content differs")


def source_revision(source_root: Path) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(source_root), "rev-parse", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except OSError:
        pass
    return os.environ.get("SOURCE_REVISION", "unknown")


def platform_name() -> str:
    return platform.system().lower() or "unknown"


def extension_versions_for_plan(plan: dict[str, Any]) -> dict[str, str]:
    return {str(key): str(value) for key, value in plan["extension_versions"].items()}


def enrich_state(
    target: Path,
    source_root: Path,
    result: dict[str, Any],
    operation: str,
    conflicts: list[str],
    removed_paths: list[str],
    history_id: str | None = None,
    refresh_paths: set[str] | None = None,
    preserve_hashes: dict[str, str] | None = None,
) -> dict[str, Any]:
    existing = result.get("state") or load_state(target)
    current_hashes = managed_hashes(existing)
    for relative, digest in (preserve_hashes or {}).items():
        if relative not in (refresh_paths or set()):
            current_hashes[relative] = digest
    for relative in removed_paths:
        current_hashes.pop(relative, None)
    plan = result["plan"]
    for relative in plan["order"]:
        if is_project_owned(relative):
            continue
        destination = target / Path(relative)
        if destination.is_file() and (
            relative not in current_hashes or relative in (refresh_paths or set())
        ):
            current_hashes[relative] = sha256_file(destination)
    records = [
        {"path": key, "hash": current_hashes[key]} for key in sorted(current_hashes)
    ]
    extensions = list(result["extensions"])
    extension_files: dict[str, list[str]] = {}
    for extension in extensions:
        extension_files[extension] = [
            relative
            for relative in plan["extension_files"].get(extension, [])
            if (target / Path(relative)).is_file()
        ]
    manifest = plan["manifest"]
    now = utc_now()
    state = dict(existing)
    state.update(
        {
            "schemaVersion": 1,
            "stateVersion": 2,
            "installer": "Copilot-SDLC-Demo",
            "installerVersion": CLI_VERSION,
            "template": "base",
            "templateVersion": str(manifest["version"]),
            "installedTemplateVersion": str(manifest["version"]),
            "agentSurface": result["surface"],
            "extensions": extensions,
            "extensionVersions": extension_versions_for_plan(plan),
            "manifestSha256": manifest["manifest_sha256"],
            "manifestHash": manifest["manifest_sha256"],
            "sourceRevision": source_revision(source_root),
            "platform": platform_name(),
            "platformDetails": {
                "system": platform.system(),
                "release": platform.release(),
                "machine": platform.machine(),
                "python": platform.python_version(),
            },
            "portableContractSha256": contract_hash(source_root),
            "installedAt": str(existing.get("installedAt", now)),
            "lastOperationAt": now,
            "lastOperation": operation,
            "files": records,
            "extensionFiles": extension_files,
            "conflicts": sorted(set(conflicts)),
        }
    )
    if history_id:
        history = [str(item) for item in state.get("history", [])]
        if history_id not in history:
            history.append(history_id)
        state["history"] = history[-20:]
    json_write(state_path(target), state)
    return state


def snapshot_before_update(
    target: Path, state: dict[str, Any], operation: str
) -> tuple[str, Path]:
    history_id = (
        dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        + "-"
        + uuid.uuid4().hex[:8]
    )
    root = target / ".sdlc" / "installer-history" / history_id
    files_root = root / "files"
    files_root.mkdir(parents=True, exist_ok=True)
    records = []
    hashes = managed_hashes(state)
    for relative, recorded_hash in sorted(hashes.items()):
        if is_project_owned(relative):
            continue
        destination = target / Path(relative)
        if not destination.is_file():
            continue
        current_hash = sha256_file(destination)
        snapshot_path = files_root / Path(relative)
        snapshot_path.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(destination, snapshot_path)
        records.append(
            {
                "path": relative,
                "recordedHash": recorded_hash,
                "currentHash": current_hash,
                "modifiedBeforeUpdate": current_hash != recorded_hash,
            }
        )
    previous_state = root / "previous-state.json"
    json_write(previous_state, state)
    metadata = {
        "schema": 1,
        "kind": "sdlc-installer-history",
        "id": history_id,
        "operation": operation,
        "createdAt": utc_now(),
        "previousState": "previous-state.json",
        "files": records,
    }
    json_write(root / "history.json", metadata)
    return history_id, root


def restore_snapshot(
    root: Path, target: Path, automatic: bool = False
) -> dict[str, Any]:
    history_path = root / "history.json"
    if not history_path.is_file():
        raise SdlcError(f"Installer history is incomplete: {root}")
    metadata = json.loads(history_path.read_text(encoding="utf-8"))
    previous_state = json.loads(
        (root / str(metadata["previousState"])).read_text(encoding="utf-8")
    )
    after_state_path = root / "after-state.json"
    after_state = (
        json.loads(after_state_path.read_text(encoding="utf-8"))
        if after_state_path.is_file()
        else {}
    )
    after_hashes = managed_hashes(after_state)
    previous_hashes = managed_hashes(previous_state)
    conflicts: list[str] = []
    restored: list[str] = []
    removed: list[str] = []
    for relative in sorted(set(after_hashes) | set(previous_hashes)):
        if is_project_owned(relative):
            continue
        destination = target / Path(relative)
        current_hash = sha256_file(destination) if destination.is_file() else ""
        expected_after = after_hashes.get(relative, "")
        if expected_after and current_hash != expected_after:
            conflicts.append(relative)
            continue
        snapshot = root / "files" / Path(relative)
        if relative in previous_hashes and snapshot.is_file():
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(snapshot, destination)
            restored.append(relative)
        elif destination.exists():
            destination.unlink()
            removed.append(relative)
    previous_state["lastOperation"] = (
        "rollback" if not automatic else "automatic-rollback"
    )
    previous_state["lastOperationAt"] = utc_now()
    previous_state["conflicts"] = sorted(set(conflicts))
    json_write(state_path(target), previous_state)
    return {
        "restored": restored,
        "removed": removed,
        "conflicts": conflicts,
        "state": previous_state,
    }


def write_evidence(target: Path, filename: str, payload: dict[str, Any]) -> None:
    json_write(target / ".sdlc" / "evidence" / filename, payload)


def check_version(source_root: Path, requested: str | None) -> dict[str, Any]:
    manifest = read_manifest(source_root / "template" / "manifest.yml")
    supported = manifest.get("supported_installers", [])
    if isinstance(supported, str):
        supported = [supported]
    if supported and CLI_VERSION not in {str(item) for item in supported}:
        raise SdlcError(
            f"Installer CLI version {CLI_VERSION} is not supported by template "
            f"{manifest['version']}; supported versions: {', '.join(map(str, supported))}."
        )
    actual = str(manifest["version"])
    if requested and requested not in {actual, "latest"}:
        raise SdlcError(
            f"Pinned template version '{requested}' is not available from this source; available version is '{actual}'."
        )
    return manifest


def version_tuple(value: str) -> tuple[int, ...]:
    match = re.match(r"^(\d+)(?:\.(\d+))?(?:\.(\d+))?", value)
    if not match:
        return (0,)
    return tuple(int(part or 0) for part in match.groups())


def extension_compatible(template_version: str, constraint: str) -> bool:
    if not constraint:
        return True
    current = version_tuple(template_version)
    for token in re.split(r"[ ,]+", constraint.strip()):
        if not token:
            continue
        match = re.match(r"(>=|<=|>|<|=)?\s*(\d+(?:\.\d+){0,2})", token)
        if not match:
            continue
        expected = version_tuple(match.group(2))
        operator = match.group(1) or "="
        if operator == ">=" and not current >= expected:
            return False
        if operator == "<=" and not current <= expected:
            return False
        if operator == ">" and not current > expected:
            return False
        if operator == "<" and not current < expected:
            return False
        if operator == "=" and not current == expected:
            return False
    return True


def validate_extensions(manifest: dict[str, Any], extensions: list[str]) -> None:
    metadata = manifest.get("extensions", {})
    selected = set(extensions)
    for extension in extensions:
        info = metadata.get(extension, {})
        compatibility = str(
            info.get("compatible_template", info.get("compatibility", ""))
        )
        if not extension_compatible(str(manifest["version"]), compatibility):
            raise SdlcError(
                f"Extension '{extension}' is incompatible with template version {manifest['version']} ({compatibility})."
            )
        required = info.get("requires", [])
        for dependency in required if isinstance(required, list) else [required]:
            if dependency and dependency not in selected:
                raise SdlcError(
                    f"Extension '{extension}' requires extension '{dependency}'."
                )
        conflicts = info.get("conflicts", [])
        for conflict in conflicts if isinstance(conflicts, list) else [conflicts]:
            if conflict and conflict in selected:
                raise SdlcError(
                    f"Extension '{extension}' conflicts with extension '{conflict}'."
                )


def installer_command(
    source_root: Path,
    target: Path,
    args: argparse.Namespace,
    update: bool,
    extensions: list[str],
    surface: str,
) -> list[str]:
    shell = args.shell or ("powershell" if os.name == "nt" else "bash")
    arguments: list[str]
    if shell == "bash":
        executable = shutil.which("bash")
        if not executable:
            raise SdlcError("Bash is required for the Bash installer.")
        script = source_root / "tools" / "scaffold-sdlc.sh"
        if not script.is_file():
            raise SdlcError(f"Bash installer not found: {script}")
        arguments = [executable, str(script), str(target)]
        if args.template:
            arguments += ["--template", args.template]
        for extension in extensions:
            arguments += ["--extension", extension]
        for variable in args.variable or []:
            arguments += ["--variable", variable]
        arguments += ["--agent-surface", surface]
        if update or args.force:
            arguments.append("--force")
        if args.validate_config:
            arguments.append("--validate-config")
        if args.feature_id:
            arguments += ["--feature-id", args.feature_id]
        if args.update_agent_surface:
            arguments.append("--update-agent-surface")
        if args.preview_agent_surface:
            arguments.append("--preview-agent-surface")
        return arguments

    executable = shutil.which("pwsh") or shutil.which("powershell")
    if not executable:
        raise SdlcError("PowerShell is required for the PowerShell installer.")
    script = source_root / "tools" / "scaffold-sdlc.ps1"
    if not script.is_file():
        raise SdlcError(f"PowerShell installer not found: {script}")
    arguments = [
        executable,
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(script),
        "-Target",
        str(target),
    ]
    if args.template:
        arguments += ["-Template", args.template]
    for extension in extensions:
        arguments += ["-Extension", extension]
    for variable in args.variable or []:
        arguments += ["-Variable", variable]
    arguments += ["-AgentSurface", surface]
    if update or args.force:
        arguments.append("-Force")
    if args.validate_config:
        arguments.append("-ValidateConfig")
    if args.feature_id:
        arguments += ["-FeatureId", args.feature_id]
    if args.update_agent_surface:
        arguments.append("-UpdateAgentSurface")
    if args.preview_agent_surface:
        arguments.append("-PreviewAgentSurface")
    return arguments


def invoke_installer(
    source_root: Path,
    target: Path,
    args: argparse.Namespace,
    update: bool,
    extensions: list[str],
    surface: str,
) -> int:
    command = installer_command(source_root, target, args, update, extensions, surface)
    environment = os.environ.copy()
    environment["SDLC_CANONICAL_BACKEND"] = "1"
    result = subprocess.run(command, cwd=str(source_root), check=False, env=environment)
    return result.returncode


def apply_removed_extensions(result: dict[str, Any]) -> list[str]:
    removed: list[str] = []
    for relative in result["removed_paths"]:
        destination = Path(result["target"]) / Path(relative)
        if destination.is_file():
            destination.unlink()
            removed.append(relative)
    return removed


def run_install(args: argparse.Namespace, update: bool) -> int:
    target = get_target(args, required=True)
    target.mkdir(parents=True, exist_ok=True)
    source_root = resolve_source(args)
    manifest = check_version(source_root, args.version)
    old_state = load_state(target)
    extensions, removals = effective_extensions(
        args, old_state, "update" if update else "init"
    )
    validate_extensions(manifest, extensions)
    surface = effective_surface(args, old_state, "update" if update else "init")
    if args.accept_conflicts and not update:
        raise SdlcError("--accept-conflicts is only valid with the update command.")
    result = compute_plan_diff(target, source_root, extensions, removals, surface)
    initial_hashes = managed_hashes(result["state"])
    initial_conflict_hashes = {
        str(operation["path"]): initial_hashes[str(operation["path"])]
        for operation in result["operations"]
        if operation["action"] == "conflict-modified"
        and str(operation["path"]) in initial_hashes
    }
    if args.dry_run:
        print_diff(result, args.json_output)
        return 0

    history_id: str | None = None
    history_root: Path | None = None
    if update and old_state:
        history_id, history_root = snapshot_before_update(target, old_state, "update")

    exit_code = invoke_installer(source_root, target, args, update, extensions, surface)
    if exit_code != 0:
        if history_root:
            try:
                restored = restore_snapshot(history_root, target, automatic=True)
                write_evidence(
                    target,
                    f"installer-update-{history_id}.json",
                    {
                        "schema": 1,
                        "kind": "sdlc-installer-update",
                        "result": "FAIL",
                        "exitCode": exit_code,
                        "historyId": history_id,
                        "automaticRollback": restored,
                        "timestamp": utc_now(),
                    },
                )
            except SdlcError:
                pass
        return exit_code

    accepted_conflicts: set[str] = set()
    if args.accept_conflicts:
        for operation in result["operations"]:
            relative = str(operation["path"])
            if operation["action"] != "conflict-modified" or is_project_owned(relative):
                continue
            candidate = result["candidates"].get(relative)
            if candidate is None:
                continue
            destination = target / Path(relative)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(candidate)
            accepted_conflicts.add(relative)

    removed_paths = apply_removed_extensions(result)
    post_result = compute_plan_diff(target, source_root, extensions, [], surface)
    conflicts = [
        item["path"]
        for item in post_result["operations"]
        if item["action"].startswith("conflict")
    ]
    state = enrich_state(
        target,
        source_root,
        post_result,
        "update" if update else "init",
        conflicts,
        removed_paths,
        history_id=history_id,
        refresh_paths=accepted_conflicts,
        preserve_hashes=initial_conflict_hashes,
    )
    if history_root:
        json_write(history_root / "after-state.json", state)
        write_evidence(
            target,
            f"installer-update-{history_id}.json",
            {
                "schema": 1,
                "kind": "sdlc-installer-update",
                "result": "PASS" if not conflicts else "CONFLICTS",
                "historyId": history_id,
                "templateVersion": manifest["version"],
                "changed": [
                    item
                    for item in post_result["operations"]
                    if item["action"] in {"add", "update", "remove"}
                ],
                "conflicts": conflicts,
                "acceptedConflicts": sorted(accepted_conflicts),
                "timestamp": utc_now(),
            },
        )
    print(f"Recorded installer state: {state_path(target)}")
    if conflicts and update:
        print(
            "Update preserved conflicts; review `sdlc diff` before using an explicit update decision.",
            file=sys.stderr,
        )
        return 2
    return 0


def resolve_source(args: argparse.Namespace) -> Path:
    if args.source:
        source = Path(args.source).expanduser().resolve()
    else:
        source = script_root().resolve()
    if not (source / "template" / "manifest.yml").is_file():
        raise SdlcError(
            f"A template source with template/manifest.yml is required: {source}"
        )
    return source


def get_target(args: argparse.Namespace, required: bool = False) -> Path:
    value = args.target_option or args.target
    if not value:
        if required:
            raise SdlcError("A target repository is required.")
        value = "."
    return Path(value).expanduser().resolve()


def check_runtime(shell: str) -> dict[str, Any]:
    checks: list[dict[str, Any]] = []
    python_ok = sys.version_info >= (3, 9)
    checks.append(
        {
            "name": "python",
            "result": "PASS" if python_ok else "FAIL",
            "detail": platform.python_version(),
        }
    )
    if shell == "bash":
        executable = shutil.which("bash")
        if not executable:
            checks.append(
                {
                    "name": "bash",
                    "result": "FAIL",
                    "detail": "Bash 4 or newer is required.",
                }
            )
        else:
            result = subprocess.run(
                [executable, "--version"], capture_output=True, text=True, check=False
            )
            match = re.search(r"version (\d+)\.(\d+)", result.stdout)
            version = tuple(int(part) for part in match.groups()) if match else (0, 0)
            checks.append(
                {
                    "name": "bash",
                    "result": "PASS" if version >= (4, 0) else "FAIL",
                    "detail": ".".join(map(str, version)),
                }
            )
    else:
        executable = shutil.which("pwsh") or shutil.which("powershell")
        if not executable:
            checks.append(
                {
                    "name": "powershell",
                    "result": "FAIL",
                    "detail": "PowerShell 5.1 or newer is required.",
                }
            )
        else:
            result = subprocess.run(
                [
                    executable,
                    "-NoProfile",
                    "-Command",
                    "$PSVersionTable.PSVersion.ToString()",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            version_text = (
                result.stdout.strip().splitlines()[-1]
                if result.stdout.strip()
                else "0.0"
            )
            version = version_tuple(version_text)
            checks.append(
                {
                    "name": "powershell",
                    "result": "PASS" if version >= (5, 1) else "FAIL",
                    "detail": version_text,
                }
            )
    return {"checks": checks}


def header_value(path: Path, name: str) -> str:
    pattern = re.compile(r"^<!--\s*" + re.escape(name) + r":\s*(.*?)\s*-->\s*$")
    try:
        for line in path.read_text(encoding="utf-8").replace("\r", "").splitlines():
            match = pattern.match(line)
            if match:
                return match.group(1)
    except OSError:
        return ""
    return ""


def run_target_validator(
    target: Path, kind: str, surface: str | None = None
) -> tuple[int, str]:
    if kind == "config":
        bash_script = target / "scripts" / "validate-sdlc-config.sh"
        ps_script = target / "scripts" / "validate-sdlc-config.ps1"
        if (
            os.name == "nt"
            and (shutil.which("pwsh") or shutil.which("powershell"))
            and ps_script.is_file()
        ):
            command = [
                shutil.which("pwsh") or shutil.which("powershell") or "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ps_script),
                "-RepoRoot",
                str(target),
            ]
        elif bash_script.is_file() and shutil.which("bash"):
            command = [
                shutil.which("bash") or "bash",
                str(bash_script),
                "--repo-root",
                str(target),
            ]
        else:
            return 1, "Installed configuration validator or its shell is missing."
    else:
        bash_script = target / "scripts" / "validate-agent-surfaces.sh"
        ps_script = target / "scripts" / "validate-agent-surfaces.ps1"
        surface = surface or "copilot"
        if (
            os.name == "nt"
            and (shutil.which("pwsh") or shutil.which("powershell"))
            and ps_script.is_file()
        ):
            command = [
                shutil.which("pwsh") or shutil.which("powershell") or "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(ps_script),
                "-RepoRoot",
                str(target),
                "-AgentSurface",
                surface,
            ]
        elif bash_script.is_file() and shutil.which("bash"):
            command = [
                shutil.which("bash") or "bash",
                str(bash_script),
                "--repo-root",
                str(target),
                "--agent-surface",
                surface,
            ]
        else:
            return 1, "Installed agent-surface validator or its shell is missing."
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    detail = (result.stdout + result.stderr).strip().splitlines()
    return result.returncode, (
        detail[-1] if detail else "validator exited without output"
    )


def doctor(args: argparse.Namespace) -> int:
    target = get_target(args)
    state = load_state(target, allow_missing=True)
    checks: list[dict[str, Any]] = []
    shell = args.shell or ("powershell" if os.name == "nt" else "bash")
    checks.extend(check_runtime(shell)["checks"])
    if not state:
        checks.append(
            {
                "name": "installer-state",
                "result": "FAIL",
                "detail": str(state_path(target)) + " is missing.",
            }
        )
    else:
        missing_fields = [
            field for field in REQUIRED_STATE_FIELDS if field not in state
        ]
        checks.append(
            {
                "name": "installer-state",
                "result": "FAIL" if missing_fields else "PASS",
                "detail": (
                    "Missing: " + ", ".join(missing_fields)
                    if missing_fields
                    else "State is recognized."
                ),
            }
        )
        records = managed_hashes(state)
        missing = [
            relative for relative in records if not (target / Path(relative)).is_file()
        ]
        modified = [
            relative
            for relative in records
            if (target / Path(relative)).is_file()
            and sha256_file(target / Path(relative)) != records[relative]
        ]
        checks.append(
            {
                "name": "managed-files",
                "result": "FAIL" if missing else ("WARN" if modified else "PASS"),
                "detail": {"missing": missing, "modified": modified},
            }
        )
        owned_records = sorted(
            relative for relative in records if is_project_owned(relative)
        )
        recorded_conflicts = [str(item) for item in state.get("conflicts", [])]
        project_owned_conflicts = sorted(
            relative for relative in recorded_conflicts if is_project_owned(relative)
        )
        checks.append(
            {
                "name": "project-owned-files",
                "result": (
                    "FAIL" if owned_records or project_owned_conflicts else "PASS"
                ),
                "detail": (
                    {
                        "managed": owned_records,
                        "conflicts": project_owned_conflicts,
                    }
                    if owned_records or project_owned_conflicts
                    else "Project-owned files are not installer-managed."
                ),
            }
        )
        checks.append(
            {
                "name": "recorded-conflicts",
                "result": "FAIL" if recorded_conflicts else "PASS",
                "detail": recorded_conflicts or "No recorded installer conflicts.",
            }
        )

    source: Path | None = None
    try:
        source = resolve_source(args)
    except SdlcError as exc:
        checks.append({"name": "source", "result": "WARN", "detail": str(exc)})
    if source and state:
        manifest = read_manifest(source / "template" / "manifest.yml")
        try:
            check_version(source, None)
            checks.append(
                {
                    "name": "installer-compatibility",
                    "result": "PASS",
                    "detail": f"CLI {CLI_VERSION} is supported.",
                }
            )
        except SdlcError as exc:
            checks.append(
                {
                    "name": "installer-compatibility",
                    "result": "FAIL",
                    "detail": str(exc),
                }
            )
        drift = manifest["manifest_sha256"] != state.get("manifestSha256")
        selected = [str(item) for item in state.get("extensions", [])]
        plan_error = ""
        try:
            source_plan = build_plan(
                source,
                target,
                selected,
                str(state.get("agentSurface", "copilot")),
            )
        except SdlcError as exc:
            source_plan = None
            plan_error = str(exc)
        checks.append(
            {
                "name": "manifest-drift",
                "result": "FAIL" if drift or plan_error else "PASS",
                "detail": (
                    "Source manifest differs from installed state."
                    if drift
                    else (
                        plan_error
                        if plan_error
                        else "Manifest matches installed state."
                    )
                ),
            }
        )
        try:
            validate_extensions(manifest, selected)
            missing_extension_files = []
            if source_plan:
                for extension in selected:
                    missing_extension_files.extend(
                        relative
                        for relative in source_plan["extension_files"].get(
                            extension, []
                        )
                        if not (target / Path(relative)).is_file()
                    )
            checks.append(
                {
                    "name": "extension-compatibility",
                    "result": "FAIL" if missing_extension_files else "PASS",
                    "detail": (
                        {"missing": sorted(set(missing_extension_files))}
                        if missing_extension_files
                        else selected or "No extensions selected."
                    ),
                }
            )
        except SdlcError as exc:
            checks.append(
                {
                    "name": "extension-compatibility",
                    "result": "FAIL",
                    "detail": str(exc),
                }
            )
    elif state:
        checks.append(
            {
                "name": "manifest-drift",
                "result": "WARN",
                "detail": "Provide --source to compare the installed manifest.",
            }
        )

    surface = str(state.get("agentSurface", "copilot")) if state else "copilot"
    contract = target / "docs" / "portable-agent-contract.md"
    expected_contract = str(state.get("portableContractSha256", "")) if state else ""
    contract_ok = contract.is_file() and (
        not expected_contract or sha256_file(contract) == expected_contract
    )
    checks.append(
        {
            "name": "portable-contract",
            "result": "PASS" if contract_ok else "FAIL",
            "detail": (
                "Contract is current."
                if contract_ok
                else "Contract is missing or stale."
            ),
        }
    )
    surface_paths = []
    if surface in {"copilot", "all"}:
        surface_paths.append(
            ("copilot", target / ".github" / "copilot-instructions.md")
        )
    if surface in {"generic", "all"}:
        surface_paths.append(("generic", target / "AGENTS.md"))
    for name, path in surface_paths:
        current_hash = header_value(path, "portable-contract-sha256")
        ok = path.is_file() and (
            not expected_contract or current_hash == expected_contract
        )
        checks.append(
            {
                "name": f"generated-{name}-surface",
                "result": "PASS" if ok else "FAIL",
                "detail": str(path) if ok else f"{path} is missing or stale.",
            }
        )

    config_exit, config_detail = run_target_validator(target, "config")
    checks.append(
        {
            "name": "configuration",
            "result": "PASS" if config_exit == 0 else "FAIL",
            "detail": config_detail,
        }
    )
    surface_exit, surface_detail = run_target_validator(target, "surface", surface)
    checks.append(
        {
            "name": "agent-surfaces",
            "result": "PASS" if surface_exit == 0 else "FAIL",
            "detail": surface_detail,
        }
    )
    result = "FAIL" if any(check["result"] == "FAIL" for check in checks) else "PASS"
    payload = {
        "schema": 1,
        "kind": "sdlc-installer-doctor",
        "result": result,
        "timestamp": utc_now(),
        "target": str(target),
        "checks": checks,
    }
    write_evidence(target, "installer-doctor.json", payload)
    if args.json_output:
        print(json.dumps(payload, indent=2))
    else:
        for check in checks:
            print(f"[{check['result']}] {check['name']}: {check['detail']}")
        print(f"Doctor result: {result}")
    return 0 if result == "PASS" else 1


def validate(args: argparse.Namespace) -> int:
    args.json_output = False
    return doctor(args)


def rollback(args: argparse.Namespace) -> int:
    target = get_target(args, required=True)
    history_root = target / ".sdlc" / "installer-history"
    if args.history_id:
        selected = history_root / args.history_id
    else:
        candidates = (
            sorted(
                (path for path in history_root.iterdir() if path.is_dir()), reverse=True
            )
            if history_root.is_dir()
            else []
        )
        if not candidates:
            raise SdlcError(f"No installer history exists under {history_root}")
        selected = candidates[0]
    restored = restore_snapshot(selected, target)
    evidence = {
        "schema": 1,
        "kind": "sdlc-installer-rollback",
        "result": "PASS" if not restored["conflicts"] else "CONFLICTS",
        "historyId": selected.name,
        "timestamp": utc_now(),
        **{key: restored[key] for key in ("restored", "removed", "conflicts")},
    }
    write_evidence(target, f"installer-rollback-{selected.name}.json", evidence)
    print(json.dumps(evidence, indent=2))
    return 0 if not restored["conflicts"] else 2


def release_files(source_root: Path, output_dir: Path) -> list[Path]:
    files: list[Path] = []
    output_resolved = output_dir.resolve()
    for path in sorted(source_root.rglob("*"), key=lambda item: item.as_posix()):
        if not path.is_file():
            continue
        relative = path.relative_to(source_root).as_posix()
        if path.resolve().is_relative_to(output_resolved):
            continue
        if any(part in {".git", ".venv", "__pycache__"} for part in path.parts):
            continue
        if relative.startswith("tests/.phase") or relative.startswith(".sdlc/"):
            continue
        files.append(path)
    return files


def verify_release(archive: Path, checksum: Path | None = None) -> dict[str, Any]:
    if not archive.is_file():
        raise SdlcError(f"Release archive not found: {archive}")
    checksum_path = checksum or archive.with_suffix(archive.suffix + ".sha256")
    expected = (
        checksum_path.read_text(encoding="utf-8").strip().split()[0]
        if checksum_path.is_file()
        else ""
    )
    actual = sha256_file(archive)
    with zipfile.ZipFile(archive) as bundle:
        names = set(bundle.namelist())
        if "template/manifest.yml" not in names:
            raise SdlcError("Release archive does not contain template/manifest.yml")
        manifest_hash = sha256_bytes(bundle.read("template/manifest.yml"))
    metadata_path = archive.with_suffix(".release.json")
    metadata = {}
    if metadata_path.is_file():
        try:
            metadata = json.loads(metadata_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise SdlcError(
                f"Release metadata is invalid: {metadata_path}: {exc}"
            ) from exc
        missing_sources = [
            item for item in metadata.get("sourceBaseFiles", []) if item not in names
        ]
        if missing_sources:
            raise SdlcError(
                "Release archive is missing manifest-covered base files: "
                + ", ".join(missing_sources)
            )
        if (
            metadata.get("manifestSha256")
            and metadata["manifestSha256"] != manifest_hash
        ):
            raise SdlcError(
                "Release manifest hash does not match template/manifest.yml in the archive."
            )
    return {
        "archive": str(archive),
        "checksum": str(checksum_path),
        "expected": expected,
        "actual": actual,
        "manifestSha256": manifest_hash,
        "result": "PASS" if expected and expected.lower() == actual.lower() else "FAIL",
    }


def release(args: argparse.Namespace) -> int:
    source = resolve_source(args)
    manifest = read_manifest(source / "template" / "manifest.yml")
    if args.verify:
        verification = verify_release(
            Path(args.verify).expanduser().resolve(),
            Path(args.checksum).expanduser().resolve() if args.checksum else None,
        )
        print(json.dumps(verification, indent=2))
        return 0 if verification["result"] == "PASS" else 1
    output_dir = Path(args.output_dir or source / "dist").expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    archive = output_dir / f"copilot-sdlc-{manifest['version']}.zip"
    files = release_files(source, output_dir)
    base_entries = collect_layer(source / "template" / "base", "base")
    source_base_files = sorted(
        path.relative_to(source).as_posix()
        for path in (entry["source"] for entry in base_entries)
    )
    installed_base_files = sorted(entry["output"] for entry in base_entries)
    with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
        for path in files:
            relative = path.relative_to(source).as_posix()
            info = zipfile.ZipInfo(relative, date_time=(2020, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o644 << 16
            bundle.writestr(info, path.read_bytes())
    digest = sha256_file(archive)
    checksum_path = archive.with_suffix(archive.suffix + ".sha256")
    checksum_path.write_text(
        f"{digest}  {archive.name}\n", encoding="utf-8", newline="\n"
    )
    metadata = {
        "schema": 1,
        "kind": "copilot-sdlc-release",
        "templateVersion": manifest["version"],
        "archive": archive.name,
        "sha256": digest,
        "manifestSha256": manifest["manifest_sha256"],
        "manifestEntries": [
            normalize_rel(str(entry)) for entry in manifest["base_installs"]
        ],
        "installedBaseFiles": installed_base_files,
        "sourceBaseFiles": source_base_files,
        "manifestMatchesBase": all(
            any(covered(entry, output) for output in installed_base_files)
            for entry in manifest["base_installs"]
        ),
        "fileCount": len(files),
        "createdAt": utc_now(),
    }
    json_write(
        output_dir / f"copilot-sdlc-{manifest['version']}.release.json", metadata
    )
    print(json.dumps(metadata, indent=2))
    return 0


def diff_command(args: argparse.Namespace) -> int:
    target = get_target(args)
    source = resolve_source(args)
    state = load_state(target)
    extensions, removals = effective_extensions(args, state, "diff")
    manifest = check_version(source, args.version)
    validate_extensions(manifest, extensions)
    surface = effective_surface(args, state, "diff")
    result = compute_plan_diff(target, source, extensions, removals, surface)
    print_diff(result, args.json_output)
    return 0


def add_target(parser: argparse.ArgumentParser, required: bool = False) -> None:
    parser.add_argument("target", nargs="?", help="Target repository path")
    parser.add_argument("--target", dest="target_option", help="Target repository path")
    if required:
        parser.set_defaults(target_required=True)


def add_source(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--source", help="Template source repository or extracted release directory"
    )
    parser.add_argument("--version", help="Pin the template version")


def add_install_options(parser: argparse.ArgumentParser) -> None:
    add_target(parser)
    add_source(parser)
    parser.add_argument("--template", default="base")
    parser.add_argument("--extension", action="append", dest="extensions", default=None)
    parser.add_argument("--remove-extension", action="append", default=[])
    parser.add_argument("--agent-surface", choices=["copilot", "generic", "all"])
    parser.add_argument("--variable", action="append", default=[])
    parser.add_argument("--feature-id")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--accept-conflicts", action="store_true")
    parser.add_argument("--validate-config", action="store_true")
    parser.add_argument("--update-agent-surface", action="store_true")
    parser.add_argument("--preview-agent-surface", action="store_true")
    parser.add_argument("--shell", choices=["bash", "powershell"])
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--json", dest="json_output", action="store_true")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="sdlc",
        description="Install, diagnose, validate, update, and roll back the Copilot SDLC template.",
    )
    parser.add_argument("--cli-version", action="version", version=CLI_VERSION)
    commands = parser.add_subparsers(dest="command", required=True)

    init_parser = commands.add_parser(
        "init", help="Install the template into a target repository"
    )
    add_install_options(init_parser)
    init_parser.set_defaults(handler=lambda args: run_install(args, False))

    update_parser = commands.add_parser(
        "update", help="Safely update an existing installation"
    )
    add_install_options(update_parser)
    update_parser.set_defaults(handler=lambda args: run_install(args, True))

    diff_parser = commands.add_parser(
        "diff", help="Preview the installation or update plan"
    )
    add_install_options(diff_parser)
    diff_parser.set_defaults(handler=diff_command)

    doctor_parser = commands.add_parser("doctor", help="Diagnose an installed template")
    add_target(doctor_parser)
    add_source(doctor_parser)
    doctor_parser.add_argument("--shell", choices=["bash", "powershell"])
    doctor_parser.add_argument("--json", dest="json_output", action="store_true")
    doctor_parser.set_defaults(handler=doctor)

    validate_parser = commands.add_parser(
        "validate", help="Run installer, configuration, and surface validation"
    )
    add_target(validate_parser)
    add_source(validate_parser)
    validate_parser.add_argument("--shell", choices=["bash", "powershell"])
    validate_parser.set_defaults(handler=validate)

    rollback_parser = commands.add_parser(
        "rollback", help="Restore the most recent safe installer snapshot"
    )
    add_target(rollback_parser, required=True)
    rollback_parser.add_argument("--history-id")
    rollback_parser.set_defaults(handler=rollback)

    release_parser = commands.add_parser(
        "release", help="Create or verify a checksum-bound release archive"
    )
    add_source(release_parser)
    release_parser.add_argument("--output-dir")
    release_parser.add_argument("--verify")
    release_parser.add_argument("--checksum")
    release_parser.set_defaults(handler=release)
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except SdlcError as exc:
        print(f"[FAIL] {exc}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("[FAIL] Cancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
