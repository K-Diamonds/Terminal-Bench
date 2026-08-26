#!/usr/bin/env python3
"""Ensure Harbor command evidence never contains secrets."""
from __future__ import annotations

import re
import sys
from pathlib import Path

SECRET_ENV_KEYS = {
    "OPENAI_API_KEY",
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "MODAL_TOKEN_ID",
    "MODAL_TOKEN_SECRET",
    "GEMINI_API_KEY",
    "HARBOR_API_KEY",
}

ALLOWED_AE_VALUES = {
    ("CODEX_FORCE_AUTH_JSON", "1"),
    ("CODEX_FORCE_AUTH_JSON", "true"),
    ("CLAUDE_FORCE_OAUTH", "1"),
    ("CLAUDE_FORCE_OAUTH", "true"),
}


def assert_safe_command_text(text: str) -> None:
    for key in SECRET_ENV_KEYS:
        if re.search(rf"{re.escape(key)}\s*=", text, re.I):
            raise ValueError(f"secret env key present in command evidence: {key}")
    if re.search(r"sk-[A-Za-z0-9]{10,}", text):
        raise ValueError("api key pattern present in command evidence")
    for line in text.splitlines():
        if "--ae" not in line:
            continue
        for match in re.finditer(r"--ae\s+(\S+)=([^'\s]+)", line):
            key, val = match.group(1), match.group(2)
            if key in SECRET_ENV_KEYS:
                raise ValueError(f"--ae forwards secret {key}")
            if key.endswith("_TOKEN") or key.endswith("_SECRET") or key.endswith("_KEY"):
                if (key, val) not in ALLOWED_AE_VALUES and val not in {"1", "true"}:
                    raise ValueError(f"--ae may not carry secret value for {key}")


def main() -> None:
    path = Path(sys.argv[1])
    assert_safe_command_text(path.read_text())
    print("PASS")


if __name__ == "__main__":
    main()
