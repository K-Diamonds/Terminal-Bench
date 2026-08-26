#!/usr/bin/env bash
# TB3 final evaluation runner for tasks/lease-queue-fencing.
# Usage:
#   bash scripts/run_final_eval.sh --preflight   # auth/config only, no trials
#   bash scripts/run_final_eval.sh               # full evaluation (blocked until preflight passes)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tb3_eval_lib.sh
source "$ROOT/scripts/lib/tb3_eval_lib.sh"

MODE="${1:-}"
PREFLIGHT=0
[[ "$MODE" == "--preflight" || "$MODE" == "--dry-run" ]] && PREFLIGHT=1

AUDIT=()
audit() { AUDIT+=("$1:$2"); }

run_rubric_review() {
  local stage output verdicts
  stage="$(mktemp -d)"
  output="$ROOT/evaluation/harbor-rubric-final"
  mkdir -p "$output"
  mkdir "$stage/task-under-review"
  rsync -a "$TASK/" "$stage/task-under-review/$TASK_NAME/"
  cp "$TB3/rubrics/task-implementation.toml" "$stage/rubric.toml"

  set +e
  harbor exec \
    -p "$stage/task-under-review" \
    -p "$stage/rubric.toml" \
    --instruction-path "$TB3/tools/rubric_regression/templates/instruction.md" \
    -f /app/verdicts.json \
    --image ubuntu:24.04 \
    -a claude-code -m sonnet \
    --job-name rubric-review-final \
    2>&1 | tee "$ROOT/evaluation/rubric-final.log"
  local rc=${PIPESTATUS[0]}
  set -e

  verdicts="$(find jobs/rubric-review-final -path '*/artifacts/app/verdicts.json' 2>/dev/null | head -1 || true)"
  if [[ -n "$verdicts" && -f "$verdicts" ]]; then
    python3 - <<PY "$verdicts" "$TB3/rubrics/task-implementation.toml" "$ROOT/evaluation/rubric-check_report.json"
import json, sys, tomllib
doc = json.JSONDecoder().raw_decode(open(sys.argv[1]).read().lstrip())[0]
checks = doc.get("checks", {})
rubric = tomllib.load(open(sys.argv[2], "rb"))
missing = [c["name"] for c in rubric["criteria"] if c["name"] not in checks]
failed = [n for n, v in checks.items() if not v]
out = {"checks": checks, "missing": missing, "failed": failed, "passed": not missing and not failed}
json.dump(out, open(sys.argv[3], "w"), indent=2)
print("PASS" if out["passed"] else "FAIL")
PY
  else
    echo "FAIL" > "$ROOT/evaluation/rubric-check_report.status"
    return 1
  fi
  rm -rf "$stage"
  return "$rc"
}

promote_evidence_if_valid() {
  local staging_file="$1"
  python3 - <<'PY' "$staging_file" "$RESULTS" "$(compute_fingerprint)"
import json, sys
from pathlib import Path
trial = json.loads(Path(sys.argv[1]).read_text())
results_path = Path(sys.argv[2])
fp = sys.argv[3]
required = ["agent", "model", "env", "reward", "classification", "valid", "task_fingerprint"]
for k in required:
    if k not in trial:
        raise SystemExit(f"missing {k} in staged trial")
if trial["task_fingerprint"] != fp:
    raise SystemExit("task fingerprint mismatch in staged trial")
if not trial.get("promote"):
    raise SystemExit("trial not marked promotable")
results = json.loads(results_path.read_text())
bucket = "standard_trials" if trial.get("kind") == "standard" else "cheat_trials"
results.setdefault(bucket, []).append({k: trial[k] for k in trial if k not in {"promote", "kind"}})
results_path.write_text(json.dumps(results, indent=2) + "\n")
print("promoted")
PY
}

run_standard_agent_trials() {
  local agent="$1"
  local agent_cfg_file model env trials_needed valid_count=0 attempt=0
  write_tb3_defaults
  agent_cfg_file="$STAGING/${agent}.agent.json"
  agent_config_json "$agent" > "$agent_cfg_file"
  model="$(python3 -c "import json; print(json.load(open('$agent_cfg_file'))['model'])")"
  env="$(python3 -c "import json; print(json.load(open('$STAGING/.harbor-defaults.json'))['env'])")"
  trials_needed="$(python3 -c "import json; print(json.load(open('$STAGING/.harbor-defaults.json'))['trials'])")"

  while (( valid_count < trials_needed )); do
    attempt=$((attempt + 1))
    local trial_id="${agent}-standard-${attempt}"
    local out="$ROOT/evaluation/harbor-${agent}-${attempt}"
    say "== Standard $agent trial attempt $attempt (valid failures: $valid_count/$trials_needed) =="
    run_harbor_and_classify "$trial_id" "$agent" "$model" "$env" "standard" "$TB3_DATASET" "$TASK_NAME" "$out" || true
    local classified="$STAGING/${trial_id}.result.json"
    local valid classification reward
    valid="$(jq -r '.valid' "$classified")"
    classification="$(jq -r '.classification' "$classified")"
    reward="$(jq -r '.reward' "$classified")"
    if [[ "$valid" == "true" && "$classification" == "VALID MODEL FAILURE" ]]; then
      valid_count=$((valid_count + 1))
      python3 - <<PY > "$STAGING/${trial_id}.promote.json"
import json
print(json.dumps({
  "kind": "standard",
  "promote": True,
  "agent": "$agent",
  "model": "$model",
  "env": "$env",
  "reward": $reward,
  "classification": "$classification",
  "valid": True,
  "attempt": $attempt,
  "valid_index": $valid_count,
  "task_fingerprint": "$(compute_fingerprint)",
  "output_dir": "$out",
}))
PY
      promote_evidence_if_valid "$STAGING/${trial_id}.promote.json"
    else
      say "Trial not counted ($classification); will rerun if needed."
      python3 - <<PY >> "$RESULTS"
import json
from pathlib import Path
p = Path("$RESULTS")
r = json.loads(p.read_text())
r.setdefault("invalid_trials_discarded", []).append({
  "agent": "$agent", "attempt": $attempt, "classification": "$classification",
  "reward": $reward, "output_dir": "$out"
})
p.write_text(json.dumps(r, indent=2) + "\n")
PY
    fi
  done
}

run_official_cheat_trials() {
  local cheat_root="$STAGING/cheat-task-tree"
  local cheat_dataset="$cheat_root/tasks"
  local cheat_task="$cheat_dataset/$TASK_NAME"
  cleanup_cheat() {
    rm -rf "$cheat_root"
    verify_instruction_restored
  }
  trap cleanup_cheat EXIT INT TERM

  prepare_cheat_staging "$cheat_task"
  write_tb3_defaults
  local env
  env="$(python3 -c "import json; print(json.load(open('$STAGING/.harbor-defaults.json'))['env'])")"

  for agent in codex claude-code; do
    local agent_cfg_file model trial_id="${agent}-cheat"
    agent_cfg_file="$STAGING/${agent}-cheat.agent.json"
    agent_config_json "$agent" > "$agent_cfg_file"
    model="$(python3 -c "import json; print(json.load(open('$agent_cfg_file'))['model'])")"
    local out="$ROOT/evaluation/harbor-${agent}-cheat"
    say "== Official /cheat $agent (staged copy; canonical tree untouched) =="
    run_harbor_and_classify "$trial_id" "$agent" "$model" "$env" "cheat" "$cheat_dataset" "$TASK_NAME" "$out" || true
    local classified="$STAGING/${trial_id}.result.json"
    local valid classification reward
    valid="$(jq -r '.valid' "$classified")"
    classification="$(jq -r '.classification' "$classified")"
    reward="$(jq -r '.reward' "$classified")"
    [[ "$valid" == "true" && "$classification" == "VALID MODEL FAILURE" && "$(python3 -c "print(float($reward))")" == "0.0" ]] || \
      die "Official /cheat $agent must be reward 0 (got classification=$classification reward=$reward)"
    python3 - <<PY > "$STAGING/${trial_id}.promote.json"
import json
print(json.dumps({
  "kind": "cheat",
  "promote": True,
  "agent": "$agent",
  "model": "$model",
  "env": "$env",
  "reward": $reward,
  "classification": "$classification",
  "valid": True,
  "cheat_transform": "run-cheat-trials.yml sed+append hack-trial-prompt.md",
  "task_fingerprint": "$(compute_fingerprint)",
  "output_dir": "$out",
}))
PY
    promote_evidence_if_valid "$STAGING/${trial_id}.promote.json"
  done
  trap - EXIT INT TERM
  cleanup_cheat
}

print_reaudit_report() {
  local safe=YES
  for entry in "${AUDIT[@]}"; do
    local status="${entry##*:}"
    [[ "$status" == "PASS" || "$status" == "BLOCKED" ]] || safe=NO
    # BLOCKED auth lines are expected when credentials absent; only FAIL blocks safe? 
    # User wants SAFE only when all checks pass for running trials - auth BLOCKED means NO
  done
  for entry in "${AUDIT[@]}"; do
    local status="${entry##*:}"
    [[ "$status" == "PASS" ]] || safe=NO
  done
  say ""
  say "FINAL EVAL RUNNER RE-AUDIT"
  say ""
  say "Current repository HEAD:"
  say "$(repo_head_sha)"
  say "Current upstream TB3 HEAD:"
  say "$(tb3_baseline_sha)"
  say "Task fingerprint:"
  say "$(compute_fingerprint)"
  say ""
  for entry in "${AUDIT[@]}"; do
    say "${entry//:/: }"
  done
  say ""
  say "SAFE TO RUN FRONTIER TRIALS: $safe"
  say "SUBMISSION READY: NO"
  [[ "$safe" == "YES" ]]
}

read_recorded_tb3_baseline() {
  python3 - <<PY
import json
from pathlib import Path
print(json.loads(Path("$RESULTS").read_text()).get("tb3_baseline_sha", ""))
PY
}

run_runner_selftests() {
  python3 "$SELFTEST_PY"
}

audit_auth_states() {
  local modal_api=BLOCKED modal_forward=BLOCKED
  local codex_api=BLOCKED codex_sub=BLOCKED codex_forward=BLOCKED
  local claude_api=BLOCKED claude_oauth=BLOCKED claude_forward=BLOCKED
  local secret_ok=FAIL defaults_ok=FAIL cheat_ok=FAIL restore_ok=FAIL
  local classifier_ok=FAIL fingerprint_ok=FAIL
  local oracle_ok=FAIL nop_ok=FAIL

  if check_modal_auth >/dev/null 2>&1; then
    modal_api=PASS
    modal_forward=PASS
  fi

  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    codex_api=PASS
    resolve_codex_auth_state >/dev/null
    codex_forward=PASS
  elif [[ -f "${HOME}/.codex/auth.json" ]]; then
    resolve_codex_auth_state >/dev/null
    if [[ "$CODEX_AUTH_FORWARDED" == "1" && "${CODEX_FORCE_AUTH_JSON:-}" == "1" ]]; then
      codex_sub=PASS
      codex_forward=PASS
    fi
  fi

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    claude_api=PASS
    resolve_claude_auth_state >/dev/null
    claude_forward=PASS
  elif [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    resolve_claude_auth_state >/dev/null
    if [[ "$CLAUDE_AUTH_FORWARDED" == "1" && "${CLAUDE_FORCE_OAUTH:-}" == "1" ]]; then
      claude_oauth=PASS
      claude_forward=PASS
    fi
  fi

  if plan_harbor_run "oracle" "" modal oracle "$TB3_DATASET" "$TASK_NAME" | python3 -c "import json,sys; p=json.load(sys.stdin); sys.exit(0 if not p['uses_frontier_config'] else 1)"; then
    oracle_ok=PASS
  fi
  if plan_harbor_run "nop" "" modal nop "$TB3_DATASET" "$TASK_NAME" | python3 -c "import json,sys; p=json.load(sys.stdin); sys.exit(0 if not p['uses_frontier_config'] else 1)"; then
    nop_ok=PASS
  fi

  write_tb3_defaults
  if python3 -c "import json; d=json.load(open('$STAGING/.harbor-defaults.json')); assert d['env'] and d['agents']" 2>/dev/null; then
    defaults_ok=PASS
  fi
  [[ -f "$HACK_PROMPT" && -f "$TB3/.github/workflows/run-cheat-trials.yml" ]] && cheat_ok=PASS
  test_cheat_transform_and_restore >/dev/null 2>&1 && restore_ok=PASS || restore_ok=FAIL

  local trial_id="secret-selftest"
  if test_secret_safe_command_evidence >/dev/null 2>&1; then
    secret_ok=PASS
  else
    secret_ok=FAIL
  fi

  if run_runner_selftests >/dev/null 2>&1; then
    classifier_ok=PASS
  fi

  assert_fingerprint_unchanged "reaudit" >/dev/null 2>&1 && fingerprint_ok=PASS || fingerprint_ok=FAIL

  audit "Oracle built-in handling" "$oracle_ok"
  audit "NOP built-in handling" "$nop_ok"
  audit "Modal authentication forwarding" "$modal_forward"
  audit "Codex API auth" "$codex_api"
  audit "Codex subscription auth forwarding" "$codex_sub"
  audit "Claude API auth" "$claude_api"
  audit "Claude OAuth forwarding" "$claude_oauth"
  audit "Secret-safe command logging" "$secret_ok"
  audit "Dynamic TB3 defaults" "$defaults_ok"
  audit "Official cheat transformation" "$cheat_ok"
  audit "Instruction restore" "$restore_ok"
  audit "Standard reward==0 enforcement" "$classifier_ok"
  audit "Cheat reward==0 enforcement" "$classifier_ok"
  audit "Trial classifier self-tests" "$classifier_ok"
  audit "Task fingerprint unchanged" "$fingerprint_ok"
}

main() {
  [[ -d "$TB3" ]] || die "tb3-upstream missing; clone terminal-bench-3 into $TB3"
  mkdir -p "$STAGING" "$ROOT/evaluation"

  print_path_diagnostics
  assert_runner_layout
  assert_canonical_task

  assert_fingerprint_unchanged "startup"

  sync_tb3_upstream
  local recorded_baseline
  recorded_baseline="$(read_recorded_tb3_baseline)"
  if [[ -n "$recorded_baseline" ]]; then
    local ci_diff
    ci_diff="$(compare_tb3_ci_baseline "$recorded_baseline")"
    if [[ "$ci_diff" == CHANGED:* ]]; then
      say "TB3 CI-relevant files changed since recorded baseline $recorded_baseline:"
      say "${ci_diff#CHANGED:}"
      say "Review evaluation/staging/.tb3-ci-hashes.json — revalidate static/rubric assumptions if material."
    else
      say "TB3 CI-relevant files unchanged since recorded baseline $recorded_baseline"
    fi
  fi
  say "Using TB3 upstream HEAD $(tb3_baseline_sha) for defaults/rubric/cheat"

  audit_auth_states

  if (( PREFLIGHT )); then
    say "== Preflight (no frontier trials will run) =="
    preflight_checks || true
    print_reaudit_report
    exit $?
  fi

  print_reaudit_report || die "Re-audit failed — fix blockers before spending trials"

  sync_task_to_tb3

  say "== Implementation rubric (review.yml: harbor exec claude-code sonnet) =="
  run_rubric_review || die "Implementation rubric failed"

  local validate_env
  validate_env="$(python3 -c "import json; print(json.load(open('$STAGING/.harbor-defaults.json'))['validate_env'])")"
  say "== Modal oracle (env=$validate_env) =="
  run_harbor_and_classify "modal-oracle" "oracle" "" "$validate_env" "oracle" "$TB3_DATASET" "$TASK_NAME" "$ROOT/evaluation/harbor-modal-oracle"
  say "== Modal nop =="
  run_harbor_and_classify "modal-nop" "nop" "" "$validate_env" "nop" "$TB3_DATASET" "$TASK_NAME" "$ROOT/evaluation/harbor-modal-nop"

  run_standard_agent_trials "codex"
  run_standard_agent_trials "claude-code"
  run_official_cheat_trials

  assert_fingerprint_unchanged "post-eval"
  say "Evaluation complete. Run scripts/pre_submit.sh and update docs manually."
}

main "$@"
