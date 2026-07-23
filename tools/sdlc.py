#!/usr/bin/env python3
from pathlib import Path
import runpy

if __name__ == "__main__":
    source = (
        Path(__file__).resolve().parent.parent
        / "template"
        / "base"
        / "scripts"
        / "sdlc.py"
    )
    if not source.is_file():
        raise SystemExit(f"Canonical SDLC CLI is missing: {source}")
    runpy.run_path(str(source), run_name="__main__")
