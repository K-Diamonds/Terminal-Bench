#!/usr/bin/env python3
"""Classify Harbor trial outcomes for final evaluation evidence."""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


INVALID_PATTERNS: list[tuple[str, str]] = [
    (r"Modal requires authentication", "INVALID — Modal/container"),
    (r"MODAL_TOKEN", "INVALID — auth"),
    (r"apiKeySource=none", "INVALID — auth"),
    (r"401 Unauthorized|403 Forbidden", "INVALID — API/provider"),
    (r"rate limit|RateLimit|429", "INVALID — rate limit"),
    (r"NonZeroAgentExitCodeError", "INVALID — agent crash"),
    (r"AgentTimeoutError", "INVALID — infrastructure timeout"),
    (r"VerifierTimeoutError", "INVALID — infrastructure timeout"),
    (r"ApiUsageLimitError", "INVALID — API/provider"),
    (r"AuthenticationError|authentication failed|not authenticated", "INVALID — auth"),
    (r"Connection refused|Connection reset|timed out waiting", "INVALID — infrastructure timeout"),
]


def _find_trial_result(output_dir: Path) -> Path | None:
    candidates = sorted(output_dir.rglob("result.json"))
    trial_results = [p for p in candidates if "__" in str(p.parent.name)]
    if trial_results:
        return trial_results[-1]
    return candidates[-1] if candidates else None


def classify(
    output_dir: Path,
    log_text: str,
    *,
    expected_agent: str,
    expected_model: str,
    expected_env: str,
    trial_kind: str,
) -> dict[str, Any]:
    result_path = _find_trial_result(output_dir)
    combined = log_text
    data: dict[str, Any] = {}
    if result_path and result_path.exists():
        combined += "\n" + result_path.read_text(errors="replace")
        try:
            data = json.loads(result_path.read_text())
        except json.JSONDecodeError:
            return {
                "classification": "INVALID — verifier error",
                "valid": False,
                "reward": None,
                "result_path": str(result_path),
                "reason": "unparseable result.json",
            }

    for pattern, label in INVALID_PATTERNS:
        if re.search(pattern, combined, re.I):
            return {
                "classification": label,
                "valid": False,
                "reward": _extract_reward(data, log_text),
                "result_path": str(result_path) if result_path else None,
                "reason": f"log/result matched {label}",
            }

    exc = data.get("exception_info") or {}
    if exc.get("exception_type"):
        et = str(exc["exception_type"])
        if et in {"AgentTimeoutError", "VerifierTimeoutError", "CancelledError"}:
            label = "INVALID — infrastructure timeout"
        elif "Auth" in et or "Credential" in et:
            label = "INVALID — auth"
        else:
            label = "INVALID — agent crash"
        return {
            "classification": label,
            "valid": False,
            "reward": _extract_reward(data, log_text),
            "result_path": str(result_path) if result_path else None,
            "reason": et,
        }

    cfg = data.get("config") or {}
    agent_cfg = cfg.get("agent") or {}
    env_cfg = (cfg.get("environment") or {}).get("type") or cfg.get("environment_type")
    agent = agent_cfg.get("name") or data.get("agent_name") or ""
    model = agent_cfg.get("model_name") or data.get("model_name") or ""
    if agent and agent != expected_agent:
        return {
            "classification": "INVALID — verifier error",
            "valid": False,
            "reward": _extract_reward(data, log_text),
            "result_path": str(result_path) if result_path else None,
            "reason": f"agent mismatch {agent} != {expected_agent}",
        }
    if model and expected_model and model != expected_model:
        return {
            "classification": "INVALID — verifier error",
            "valid": False,
            "reward": _extract_reward(data, log_text),
            "result_path": str(result_path) if result_path else None,
            "reason": f"model mismatch {model} != {expected_model}",
        }
    if env_cfg and str(env_cfg) != expected_env:
        return {
            "classification": "INVALID — verifier error",
            "valid": False,
            "reward": _extract_reward(data, log_text),
            "result_path": str(result_path) if result_path else None,
            "reason": f"env mismatch {env_cfg} != {expected_env}",
        }

    reward = _extract_reward(data, log_text)
    if reward is None:
        return {
            "classification": "INVALID — verifier error",
            "valid": False,
            "reward": None,
            "result_path": str(result_path) if result_path else None,
            "reason": "could not determine reward",
        }

    ae = data.get("agent_execution") or {}
    if expected_agent not in {"oracle", "nop"} and not ae.get("started_at"):
        return {
            "classification": "INVALID — invalid trajectory",
            "valid": False,
            "reward": reward,
            "result_path": str(result_path) if result_path else None,
            "reason": "agent_execution.started_at missing",
        }

    if trial_kind == "standard":
        if _is_zero_reward(reward):
            return {
                "classification": "VALID MODEL FAILURE",
                "valid": True,
                "reward": reward,
                "result_path": str(result_path) if result_path else None,
                "reason": "reward == 0 with completed trajectory",
            }
        return {
            "classification": "MODEL PASS",
            "valid": False,
            "reward": reward,
            "result_path": str(result_path) if result_path else None,
            "reason": "frontier model did not fail with reward 0",
        }

    if trial_kind == "cheat":
        if _is_zero_reward(reward):
            return {
                "classification": "VALID MODEL FAILURE",
                "valid": True,
                "reward": reward,
                "result_path": str(result_path) if result_path else None,
                "reason": "cheat correctly rejected with reward 0",
            }
        return {
            "classification": "MODEL PASS",
            "valid": False,
            "reward": reward,
            "result_path": str(result_path) if result_path else None,
            "reason": "cheat trial must be reward 0",
        }

    if trial_kind == "oracle":
        ok = reward >= 1.0
        return {
            "classification": "PASS" if ok else "FAIL",
            "valid": ok,
            "reward": reward,
            "result_path": str(result_path) if result_path else None,
            "reason": "oracle validation",
        }

    if trial_kind == "nop":
        ok = _is_zero_reward(reward)
        return {
            "classification": "PASS" if ok else "FAIL",
            "valid": ok,
            "reward": reward,
            "result_path": str(result_path) if result_path else None,
            "reason": "nop validation expects reward 0",
        }

    return {
        "classification": "UNKNOWN",
        "valid": False,
        "reward": reward,
        "result_path": str(result_path) if result_path else None,
        "reason": "unhandled trial kind",
    }


def _is_zero_reward(reward: float) -> bool:
    return abs(reward) < 1e-9


def _extract_reward(data: dict[str, Any], log_text: str) -> float | None:
    vr = data.get("verifier_result") or {}
    rewards = vr.get("rewards") or {}
    if rewards:
        val = next(iter(rewards.values()))
        try:
            return float(val)
        except (TypeError, ValueError):
            pass
    m = re.findall(r"Mean[:\s]+([0-9]+(?:\.[0-9]+)?)", log_text)
    if m:
        return float(m[-1])
    return None


def main() -> None:
    if len(sys.argv) != 2:
        print(json.dumps({"classification": "INVALID — verifier error", "valid": False}))
        raise SystemExit(1)
    payload = json.loads(Path(sys.argv[1]).read_text())
    out = classify(
        Path(payload["output_dir"]),
        Path(payload["log_file"]).read_text(errors="replace") if payload.get("log_file") else "",
        expected_agent=payload["expected_agent"],
        expected_model=payload["expected_model"],
        expected_env=payload["expected_env"],
        trial_kind=payload["trial_kind"],
    )
    print(json.dumps(out))


if __name__ == "__main__":
    main()
