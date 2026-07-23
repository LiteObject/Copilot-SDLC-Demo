#!/usr/bin/env python3
"""Write a small revision-bound coverage report for regression tests."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path


def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "pass"
    root = Path.cwd()
    report_path = root / ".sdlc/reports/coverage.json"
    if mode == "missing":
        report_path.unlink(missing_ok=True)
        return 0
    commit = os.environ.get("SDLC_COMMIT_SHA", "")
    tree = os.environ.get("SDLC_TREE_DIGEST", "")
    if mode == "stale":
        commit, tree = "stale-commit", "stale-tree"
    if mode == "pass":
        executed, missing = [2], [1]
    else:
        executed, missing = [1], [2]
    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(
            {
                "schema": 1,
                "commit_sha": commit,
                "tree_digest": tree,
                "files": {
                    "src/app.py": {"executed_lines": executed, "missing_lines": missing}
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
