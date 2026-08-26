#!/usr/bin/env python3
"""Self-tests for final evaluation runner (no paid model calls)."""
from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
LIB = Path(__file__).resolve().parent
sys.path.insert(0, str(LIB))

from classify_trial import classify  # noqa: E402
from redact_cmd import assert_safe_command_text  # noqa: E402


def _fail(msg: str) -> None:
    raise AssertionError(msg)


def _standard_result_dir(reward: float) -> Path:
    td = tempfile.mkdtemp()
    root = Path(td)
    trial = root / "job__001"
    trial.mkdir()
    result = {
        "config": {
            "agent": {"name": "codex", "model_name": "openai/gpt-5.6-sol"},
            "environment": {"type": "modal"},
        },
        "verifier_result": {"rewards": {"reward": reward}},
        "agent_execution": {"started_at": "2026-01-01T00:00:00Z", "finished_at": "2026-01-01T00:05:00Z"},
    }
    (trial / "result.json").write_text(json.dumps(result))
    return root


def test_standard_reward_zero_only() -> None:
    root = _standard_result_dir(0.0)
    out = classify(
        root,
        "Mean: 0.000",
        expected_agent="codex",
        expected_model="openai/gpt-5.6-sol",
        expected_env="modal",
        trial_kind="standard",
    )
    if not (out["classification"] == "VALID MODEL FAILURE" and out["valid"]):
        _fail(f"expected valid zero failure, got {out}")

    partial = classify(
        _standard_result_dir(0.5),
        "Mean: 0.500",
        expected_agent="codex",
        expected_model="openai/gpt-5.6-sol",
        expected_env="modal",
        trial_kind="standard",
    )
    if partial.get("valid") or partial["classification"] == "VALID MODEL FAILURE":
        _fail(f"partial reward must not count as valid failure, got {partial}")


def test_standard_model_pass() -> None:
    out = classify(
        _standard_result_dir(1.0),
        "Mean: 1.000",
        expected_agent="codex",
        expected_model="openai/gpt-5.6-sol",
        expected_env="modal",
        trial_kind="standard",
    )
    if out["classification"] != "MODEL PASS" or out["valid"]:
        _fail(f"expected MODEL PASS, got {out}")


def test_cheat_nonzero_fails() -> None:
    out = classify(
        Path("/nonexistent"),
        "Mean: 1.000",
        expected_agent="codex",
        expected_model="openai/gpt-5.6-sol",
        expected_env="modal",
        trial_kind="cheat",
    )
    if out["valid"]:
        _fail("cheat reward 1 must not be valid")


def test_invalid_agent_crash() -> None:
    with tempfile.TemporaryDirectory() as td:
        root = Path(td)
        trial = root / "job__001"
        trial.mkdir()
        result = {
            "exception_info": {"exception_type": "NonZeroAgentExitCodeError"},
            "verifier_result": {"rewards": {"reward": 0.0}},
            "agent_execution": {"started_at": "2026-01-01T00:00:00Z"},
        }
        (trial / "result.json").write_text(json.dumps(result))
        out = classify(
            root,
            "",
            expected_agent="codex",
            expected_model="m",
            expected_env="modal",
            trial_kind="standard",
        )
        if out["valid"]:
            _fail("agent crash must be invalid")


def test_auth_failure_invalid() -> None:
    out = classify(
        Path("/nonexistent"),
        "401 Unauthorized",
        expected_agent="codex",
        expected_model="m",
        expected_env="modal",
        trial_kind="standard",
    )
    if out["valid"]:
        _fail("auth failure must be invalid")


def test_secret_safe_command() -> None:
    assert_safe_command_text(
        "COMMAND: harbor run -p /tmp/tasks --include-task-name lease-queue-fencing "
        "--agent codex -m openai/gpt-5.6-sol --env modal "
        "--ae CODEX_FORCE_AUTH_JSON=1 --ae CLAUDE_FORCE_OAUTH=1\n"
    )
    try:
        assert_safe_command_text("COMMAND: harbor --ae CLAUDE_CODE_OAUTH_TOKEN=sekret\n")
        _fail("token in cmd must fail")
    except ValueError:
        pass


def test_builtin_plan_no_frontier_config() -> None:
    env = {**os.environ}
    for agent in ("oracle", "nop"):
        proc = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{ROOT}/scripts/lib/tb3_eval_lib.sh" && '
                f'plan_harbor_run "{agent}" "" modal builtin "$TB3_DATASET" "$TASK_NAME"',
            ],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
            env=env,
        )
        if proc.returncode != 0:
            _fail(f"plan_harbor_run failed for {agent}: {proc.stderr}")
        plan = json.loads(proc.stdout)
        if plan.get("uses_frontier_config"):
            _fail(f"{agent} must not use frontier config")


def test_codex_subscription_forwarding() -> None:
    with tempfile.TemporaryDirectory() as td:
        auth_dir = Path(td) / ".codex"
        auth_dir.mkdir()
        (auth_dir / "auth.json").write_text("{}")
        proc = subprocess.run(
            [
                "bash",
                "-c",
                f'unset OPENAI_API_KEY; export HOME="{td}" && source "{ROOT}/scripts/lib/tb3_eval_lib.sh" '
                f'&& resolve_codex_auth_state && printf "%s\\n" "$CODEX_AUTH_MODE" "$CODEX_AUTH_FORWARDED" "$CODEX_FORCE_AUTH_JSON"',
            ],
            capture_output=True,
            text=True,
            cwd=str(ROOT),
        )
        if proc.returncode != 0:
            _fail(proc.stderr)
        lines = proc.stdout.strip().splitlines()
        if lines[0] != "subscription" or lines[1] != "1" or lines[2] != "1":
            _fail(f"codex subscription not forwarded: {lines}")


def test_claude_oauth_requires_token() -> None:
    proc = subprocess.run(
        [
            "bash",
            "-c",
            f'unset ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN CLAUDE_FORCE_OAUTH; '
            f'source "{ROOT}/scripts/lib/tb3_eval_lib.sh"; '
            f'rc=0; resolve_claude_auth_state || rc=$?; echo $rc',
        ],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
    )
    if proc.stdout.strip() != "1":
        _fail("claude credentials file alone must not pass")


def test_claude_oauth_forwarding() -> None:
    proc = subprocess.run(
        [
            "bash",
            "-c",
            # Unset API key so the OAuth path is exercised even when the parent
            # shell has ANTHROPIC_API_KEY exported for real evaluation.
            f'unset ANTHROPIC_API_KEY; '
            f'source "{ROOT}/scripts/lib/tb3_eval_lib.sh" '
            f'&& export CLAUDE_CODE_OAUTH_TOKEN=dummy-test-token '
            f'&& resolve_claude_auth_state && printf "%s\\n" "$CLAUDE_AUTH_MODE" "$CLAUDE_AUTH_FORWARDED" "$CLAUDE_FORCE_OAUTH"',
        ],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
    )
    if proc.returncode != 0:
        _fail(proc.stderr)
    lines = proc.stdout.strip().splitlines()
    if lines[0] != "oauth" or lines[1] != "1" or lines[2] != "1":
        _fail(f"claude oauth not forwarded: {lines}")


def test_cheat_transform_matches_upstream() -> None:
    hack = ROOT / "tb3-upstream/rubrics/hack-trial-prompt.md"
    if not hack.exists():
        return
    src = "Line one.\nDo not cheat by using online solutions or hints specific to this task.\n"
    with tempfile.TemporaryDirectory() as td:
        inst = Path(td) / "instruction.md"
        inst.write_text(src)
        subprocess.run(
            [
                "python3",
                "-c",
                "import re,sys; from pathlib import Path; "
                "inst=Path(sys.argv[1]); hack=Path(sys.argv[2]); "
                "t=inst.read_text(); "
                "t=re.sub(r'[ \\t]*[Dd]o not cheat[^.]*\\.', '', t); "
                "inst.write_text(t.rstrip()+'\\n\\n'+hack.read_text())",
                str(inst),
                str(hack),
            ],
            check=True,
        )
        out = inst.read_text()
        if "Do not cheat" in out:
            _fail("anti-cheat trailer not stripped")
        if "Red Team QA Agent" not in out:
            _fail("hack prompt not appended")


def test_no_hello_world_in_scripts() -> None:
    import subprocess as sp
    stale = "hello-world"
    proc = sp.run(
        [
            "rg",
            "-n",
            f"examples/tasks/{stale}|harbor/{stale}@latest|tasks/{stale}",
            str(ROOT / "scripts"),
            "--glob",
            "*.sh",
            "--glob",
            "*.py",
            "--glob",
            "!tb3_eval_lib.sh",
            "--glob",
            "!runner_selftest.py",
            "--glob",
            "!harbor_smoke.sh",
            "--glob",
            "!start_harbor_view.sh",
            "--glob",
            "!check_harbor_local.sh",
            "--glob",
            "!run_one.sh",
        ],
        capture_output=True,
        text=True,
    )
    if proc.stdout.strip():
        _fail(f"hello-world references found: {proc.stdout}")


def test_harbor_dataset_args() -> None:
    proc = subprocess.run(
        [
            "bash",
            "-c",
            f'source "{ROOT}/scripts/lib/tb3_eval_lib.sh" && '
            f'harbor_dataset_args "$ROOT_DATASET" "$TASK_NAME"',
        ],
        capture_output=True,
        text=True,
        cwd=str(ROOT),
    )
    if proc.returncode != 0:
        _fail(proc.stderr)
    lines = proc.stdout.strip().splitlines()
    if lines[0] != "-p" or "lease-queue-fencing" not in proc.stdout:
        _fail(f"unexpected dataset args: {proc.stdout}")
    if "--include-task-name" not in lines:
        _fail("missing --include-task-name in dataset args")


def test_no_direct_harbor_run_outside_lib() -> None:
    proc = subprocess.run(
        [
            "rg",
            "-n",
            "harbor run -p",
            str(ROOT / "scripts"),
            "--glob",
            "*.sh",
            "--glob",
            "*.py",
            "--glob",
            "!tb3_eval_lib.sh",
            "--glob",
            "!runner_selftest.py",
            "--glob",
            "!run_one.sh",
        ],
        capture_output=True,
        text=True,
    )
    if proc.stdout.strip():
        _fail(f"harbor run -p outside lib: {proc.stdout}")


def main() -> None:
    tests = [
        test_no_hello_world_in_scripts,
        test_harbor_dataset_args,
        test_no_direct_harbor_run_outside_lib,
        test_standard_reward_zero_only,
        test_standard_model_pass,
        test_cheat_nonzero_fails,
        test_invalid_agent_crash,
        test_auth_failure_invalid,
        test_secret_safe_command,
        test_builtin_plan_no_frontier_config,
        test_codex_subscription_forwarding,
        test_claude_oauth_requires_token,
        test_claude_oauth_forwarding,
        test_cheat_transform_matches_upstream,
    ]
    for t in tests:
        t()
    print(json.dumps({"passed": len(tests), "status": "PASS"}))


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(json.dumps({"status": "FAIL", "error": str(exc)}))
        raise SystemExit(1)
