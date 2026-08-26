#!/usr/bin/env bash
# Pre-submission gate: validates evidence integrity and local Docker smoke tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tb3_eval_lib.sh
source "$ROOT/scripts/lib/tb3_eval_lib.sh"

FAIL=0

say() { printf '%s\n' "$*"; }
fail() { say "FAIL: $*"; FAIL=1; }
pass() { say "PASS: $*"; }

say "== pre_submit $(date -u +%Y-%m-%dT%H:%M:%SZ) =="
print_path_diagnostics
assert_runner_layout
assert_canonical_task
check_no_hello_world_in_runner || fail "stale hello-world reference in scripts"

[[ -f "$RESULTS" ]] || fail "missing evaluation/results.json"

# Placeholder author metadata
if rg -n 'Hiring Submission|candidate@example.com' "$TASK/task.toml" >/dev/null; then
  fail "placeholder author metadata in task.toml"
else
  pass "author metadata not placeholder"
fi

# Baseline SHA present
if ! rg -q '9597744614a56cb5d7d52d22a9fa087b7249256c' "$RESULTS" "$ROOT/README.md" "$ROOT/docs/TB3_REQUIREMENTS_AUDIT.md"; then
  fail "current TB3 baseline SHA missing from docs/results"
else
  pass "baseline SHA documented"
fi

# Evidence schema (v2): no repository_head_sha stamp loop
python3 - "$RESULTS" <<'PY' || fail "evidence schema check"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
required = [
    "task", "task_content_commit", "task_tree_fingerprint", "tb3_baseline_sha",
    "evidence_generated_from_commit", "checks", "oracle", "nop",
    "standard_trials", "cheat_trials", "submission_ready",
]
for k in required:
    if k not in data:
        print("missing", k); sys.exit(1)
if "repository_head_sha" in data:
    print("remove repository_head_sha — use task_content_commit + evidence_generated_from_commit"); sys.exit(1)
if not data.get("task_tree_fingerprint"):
    print("empty task_tree_fingerprint"); sys.exit(1)
if not data.get("task_content_commit"):
    print("empty task_content_commit"); sys.exit(1)
print("evidence schema ok")
PY
pass "evidence schema v2"

# Dirty task files
if [[ -n "$(git -C "$ROOT" status --porcelain -- "$TASK")" ]]; then
  fail "dirty task files (commit or restore before submit)"
else
  pass "task tree clean in git"
fi

# allow_internet must be omitted
if rg -n 'allow_internet' "$TASK/task.toml" >/dev/null; then
  fail "task.toml must omit allow_internet (TB3 CI rejects true and false)"
else
  pass "allow_internet omitted"
fi

# Secrets heuristic
if rg -n 'OPENAI_API_KEY[[:space:]]*=[[:space:]]*sk-|ANTHROPIC_API_KEY[[:space:]]*=[[:space:]]*sk-|CLAUDE_CODE_OAUTH_TOKEN[[:space:]]*=[[:space:]]*[^<[:space:]]|sk-[A-Za-z0-9]{20,}' \
  "$ROOT/tasks" "$ROOT/docs" "$ROOT/README.md" "$ROOT/scripts" "$RESULTS" 2>/dev/null; then
  fail "possible real secrets in content"
else
  pass "secret scan clean"
fi
[[ -f "$ROOT/.env" ]] && fail ".env present" || pass "no .env"

# Static checks
if [[ ! -d "$TB3/checks" ]]; then
  fail "TB3 checks missing at $TB3"
else
  rsync -a --delete "$TASK/" "$TB3/tasks/$TASK_NAME/"
  pushd "$TB3" >/dev/null
  for check in checks/check-*.sh; do
    if ! bash "$check" "tasks/$TASK_NAME" >/tmp/pre-submit-check.out 2>&1; then
      cat /tmp/pre-submit-check.out
      fail "static $(basename "$check")"
    fi
  done
  popd >/dev/null
  [[ $FAIL -eq 0 ]] && pass "static checks"
fi

# Harbor oracle/nop if available
if command -v harbor >/dev/null && docker info >/dev/null 2>&1; then
  sync_task_to_tb3
  local ds_args=()
  while IFS= read -r _arg; do
    [[ -n "$_arg" ]] && ds_args+=("$_arg")
  done < <(harbor_dataset_args "$TB3_DATASET" "$TASK_NAME")
  OUT=$(harbor run "${ds_args[@]}" --agent oracle --env docker -o "$ROOT/evaluation/pre-submit-oracle" 2>&1 || true)
  printf '%s\n' "$OUT" > "$ROOT/evaluation/pre-submit-oracle.log"
  echo "$OUT" | rg -q 'Mean:[[:space:]]*1(\.0+)?' && pass "oracle Mean 1" || fail "oracle Mean != 1"
  OUT=$(harbor run "${ds_args[@]}" --agent nop --env docker -o "$ROOT/evaluation/pre-submit-nop" 2>&1 || true)
  printf '%s\n' "$OUT" > "$ROOT/evaluation/pre-submit-nop.log"
  echo "$OUT" | rg -q 'Mean:[[:space:]]*0(\.0+)?' && pass "nop Mean 0" || fail "nop Mean != 0"
else
  fail "harbor/docker unavailable"
fi

# Evidence JSON gate
python3 - "$RESULTS" <<'PY' || fail "results.json gate failed"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
oracles = [o for o in data.get("oracle", []) if o.get("reward") == 1.0 and o.get("valid")]
if len(oracles) < 5:
    print("need >=5 valid oracle reward=1 entries, have", len(oracles)); sys.exit(1)
if not (data.get("nop") or {}).get("reward") == 0.0:
    print("nop reward must be 0"); sys.exit(1)
rubric = (data.get("checks") or {}).get("implementation_rubric", {})
if rubric.get("status") not in ("PASS", "BLOCKED", "NOT RUN"):
    print("bad rubric status"); sys.exit(1)
if data.get("submission_ready") is True:
    std = data.get("standard_trials") or []
    cheat = data.get("cheat_trials") or []
    codex = [t for t in std if t.get("valid") and t.get("reward") == 0 and t.get("agent") == "codex"]
    claude = [t for t in std if t.get("valid") and t.get("reward") == 0 and t.get("agent") == "claude-code"]
    if len(codex) < 3 or len(claude) < 3:
        print("submission_ready requires 3+3 valid zero rewards"); sys.exit(1)
    if len(cheat) < 2 or any((t.get("reward") or 0) != 0 for t in cheat):
        print("cheat trials incomplete/nonzero"); sys.exit(1)
    if rubric.get("status") != "PASS":
        print("rubric must PASS for submission_ready"); sys.exit(1)
    modal_o = data.get("modal_oracle") or {}
    modal_n = data.get("modal_nop") or {}
    if modal_o.get("reward") != 1.0 or modal_n.get("reward") != 0.0:
        print("modal oracle/nop required for submission_ready"); sys.exit(1)
print("results.json ok submission_ready=", data.get("submission_ready"))
PY
pass "results.json checked"

# Fingerprint must match recorded evidence
if [[ -f "$ROOT/evaluation/task-fingerprint.sha" ]]; then
  NEW=$(compute_fingerprint)
  RECORDED=$(python3 -c "import json; print(json.load(open('$RESULTS'))['task_tree_fingerprint'])")
  if [[ "$NEW" != "$RECORDED" ]]; then
    fail "task fingerprint changed ($NEW != $RECORDED); invalidate frontier/cheat evidence"
  else
    pass "task fingerprint matches evidence"
  fi
fi

if [[ $FAIL -ne 0 ]]; then
  say "PRE_SUBMIT: FAIL"
  exit 1
fi
say "PRE_SUBMIT: PASS (local gates)"
if python3 -c "import json; print(json.load(open('$RESULTS')).get('submission_ready'))" | rg -q 'False'; then
  say "NOTE: submission_ready=false — complete rubric, Modal, frontier, cheat per docs/FINAL_EVAL_AUTH.md"
fi
exit 0
