#!/usr/bin/env bash
# Shared helpers for TB3 final evaluation runner.
set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$LIB_DIR/../.." && pwd)"
TASK_NAME="${TASK_NAME:-lease-queue-fencing}"
TASK="$ROOT/tasks/$TASK_NAME"
TB3="${TB3_ROOT:-$ROOT/tb3-upstream}"
TB3_TASK="$TB3/tasks/$TASK_NAME"
TB3_DATASET="$TB3/tasks"
ROOT_DATASET="$ROOT/tasks"
# Harbor 0.18.0: -p is a dataset directory; filter single task with --include-task-name (-i).
HARBOR_TASK_SELECTOR=(--include-task-name)
RESULTS="$ROOT/evaluation/results.json"
STAGING="$ROOT/evaluation/staging"
DEFAULTS_FILE="$TB3/.github/harbor-run-defaults.yml"
HACK_PROMPT="$TB3/rubrics/hack-trial-prompt.md"
CLASSIFY_PY="$LIB_DIR/classify_trial.py"
REDACT_PY="$LIB_DIR/redact_cmd.py"
SELFTEST_PY="$LIB_DIR/runner_selftest.py"
TB3_CI_FILES=(
  ".github/harbor-run-defaults.yml"
  ".github/workflows/run-cheat-trials.yml"
  ".github/workflows/review.yml"
  "rubrics/hack-trial-prompt.md"
  "rubrics/task-implementation.toml"
)
CODEX_AUTH_MODE=""
CODEX_AUTH_FORWARDED=0
CLAUDE_AUTH_MODE=""
CLAUDE_AUTH_FORWARDED=0
export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH}"

say() { printf '%s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

print_path_diagnostics() {
  say "ROOT=$ROOT"
  say "TB3=$TB3"
  say "TASK=$TASK"
  say "TB3_TASK=$TB3_TASK"
  say "TB3_DATASET=$TB3_DATASET"
  say "ROOT_DATASET=$ROOT_DATASET"
  say "pwd=$(pwd)"
}

assert_runner_layout() {
  [[ -d "$ROOT" ]] || die "ROOT not found: $ROOT"
  [[ -d "$TB3" ]] || die "TB3 not found: $TB3"
  [[ -d "$TASK" ]] || die "TASK not found: $TASK"
}

assert_canonical_task() {
  [[ -f "$TASK/task.toml" ]] || die "missing canonical task.toml: $TASK/task.toml"
  [[ -f "$TASK/instruction.md" ]] || die "missing canonical instruction.md: $TASK/instruction.md"
}

assert_tb3_staged_task() {
  [[ -f "$TB3_TASK/task.toml" ]] || die "missing staged task.toml: $TB3_TASK/task.toml (run sync_task_to_tb3 first)"
  [[ -f "$TB3_TASK/instruction.md" ]] || die "missing staged instruction.md: $TB3_TASK/instruction.md"
}

normalize_harbor_dataset_path() {
  local dataset_path="$1"
  [[ -d "$dataset_path" ]] || die "Harbor dataset path is not a directory: $dataset_path"
  dataset_path="$(cd "$dataset_path" && pwd)"
  printf '%s\n' "$dataset_path"
}

assert_task_in_dataset() {
  local dataset_path="$1"
  local task_name="$2"
  [[ -d "$dataset_path" ]] || die "dataset missing: $dataset_path"
  [[ -f "$dataset_path/$task_name/task.toml" ]] || \
    die "task.toml missing in dataset: $dataset_path/$task_name/task.toml"
  [[ -f "$dataset_path/$task_name/instruction.md" ]] || \
    die "instruction.md missing in dataset: $dataset_path/$task_name/instruction.md"
}

harbor_dataset_args() {
  local dataset_path="$1"
  local task_name="$2"
  dataset_path="$(normalize_harbor_dataset_path "$dataset_path")"
  assert_task_in_dataset "$dataset_path" "$task_name"
  printf '%s\n' "-p" "$dataset_path" "--include-task-name" "$task_name"
}

assert_json_has_no_hello_world() {
  local blob="$1"
  if echo "$blob" | rg -qi 'hello-world'; then
    die "FAIL — incorrect task resolution (hello-world in Harbor config/metadata)"
  fi
}

# Assert --print-config resolved a LOCAL dataset source (not registry tasks).
assert_local_dataset_resolved() {
  local resolved="$1"
  local expect_dataset="${2:-$ROOT_DATASET}"
  assert_json_has_no_hello_world "$resolved"
  python3 - <<PY "$resolved" "$expect_dataset" "$TASK_NAME"
import json, sys
from pathlib import Path

raw = sys.argv[1]
# Harbor may print non-JSON noise; take the outermost JSON object.
start = raw.find("{")
end = raw.rfind("}")
if start < 0 or end < 0:
    raise SystemExit("FAIL — no JSON object in harbor --print-config output")
data = json.loads(raw[start : end + 1])

expect_ds = Path(sys.argv[2]).expanduser().resolve()
expect_task = sys.argv[3]

tasks = data.get("tasks")
if tasks:
    # Registry Single-task uses {name, ref}; local path tasks use {path}.
    for t in tasks:
        if isinstance(t, dict) and t.get("name"):
            raise SystemExit(
                f"FAIL — registry tasks entry present (resolve_task_version path): {t!r}"
            )
    raise SystemExit(
        "FAIL — top-level tasks present; expected datasets-only local source "
        f"(got tasks={tasks!r})"
    )

datasets = data.get("datasets") or []
if not datasets:
    raise SystemExit("FAIL — resolved config missing datasets[] (local dataset required)")

ds0 = datasets[0]
path_raw = ds0.get("path")
if not path_raw:
    raise SystemExit(f"FAIL — datasets[0] missing path: {ds0!r}")
got_path = Path(str(path_raw)).expanduser().resolve()
# Config may store repo-relative "tasks"; resolve against cwd (repo root).
if not got_path.exists():
    got_path = (Path.cwd() / str(path_raw)).resolve()
if got_path != expect_ds:
    raise SystemExit(
        f"FAIL — datasets[0].path={got_path} expected {expect_ds}"
    )

names = ds0.get("task_names") or []
if expect_task not in names:
    raise SystemExit(
        f"FAIL — datasets[0].task_names={names!r} missing {expect_task!r}"
    )

print("Source mode: local dataset")
print(f"Dataset path: {got_path}")
print(f"Included task: {expect_task}")
print("Registry tasks: none")
print("harbor/hello-world registry reference: ABSENT")
PY
}

validate_harbor_run_selection() {
  local resolved
  resolved="$(harbor run --print-config "$@" 2>&1)" || die "harbor run --print-config failed"
  assert_local_dataset_resolved "$resolved" "$ROOT_DATASET"
  printf '%s\n' "$resolved"
}

verify_harbor_job_metadata() {
  local output_dir="$1"
  local trial_result
  trial_result="$(find "$output_dir" -name 'result.json' -path "*${TASK_NAME}__*" -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1 || true)"
  [[ -n "$trial_result" ]] || die "no trial result.json for ${TASK_NAME} under $output_dir"
  python3 - <<PY "$trial_result"
import json, sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
blob = json.dumps(data)
if "hello-world" in blob.lower():
    raise SystemExit("FAIL — incorrect task resolution in result.json")
name = data.get("task_name") or ""
path = (data.get("task_id") or {}).get("path") or ""
if "lease-queue-fencing" not in name and "lease-queue-fencing" not in path:
    raise SystemExit(f"FAIL — selected task is not lease-queue-fencing: name={name!r} path={path!r}")
reward = None
vr = data.get("verifier_result") or {}
if vr.get("rewards"):
    reward = next(iter(vr["rewards"].values()))
print(f"selected task_name={name}")
print(f"selected task_path={path}")
print(f"oracle reward={reward}")
if reward is None or float(reward) < 1.0:
    raise SystemExit(f"oracle reward expected 1.0, got {reward}")
PY
}

sync_task_to_tb3() {
  assert_canonical_task
  mkdir -p "$TB3/tasks"
  rsync -a --delete "$TASK/" "$TB3_TASK/"
  assert_tb3_staged_task
}

check_no_hello_world_in_runner() {
  local hits
  hits="$(rg -n 'examples/tasks/hello-world|harbor/hello-world@latest|tasks/hello-world' "$ROOT/scripts" \
    --glob '*.sh' --glob '*.py' \
    --glob '!tb3_eval_lib.sh' \
    --glob '!runner_selftest.py' \
    --glob '!harbor_smoke.sh' \
    --glob '!start_harbor_view.sh' \
    --glob '!check_harbor_local.sh' \
    --glob '!run_one.sh' \
    2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    say "Stale hello-world references in scripts:"
    say "$hits"
    return 1
  fi
  return 0
}

check_harbor_run_has_task_selector() {
  local hits
  hits="$(rg -n 'harbor run -p' "$ROOT/scripts" --glob '*.sh' --glob '*.py' \
    --glob '!tb3_eval_lib.sh' \
    --glob '!runner_selftest.py' \
    --glob '!run_one.sh' \
    2>/dev/null || true)"
  if [[ -n "$hits" ]]; then
    say "harbor run -p must only appear in tb3_eval_lib.sh (with --include-task-name):"
    say "$hits"
    return 1
  fi
  return 0
}

assert_task_paths_for_preflight() {
  python3 - <<PY
from pathlib import Path
required = [
    Path("$TASK/task.toml"),
    Path("$TASK/instruction.md"),
]
for p in required:
    assert p.exists(), f"missing {p}"
print("Task path: PASS")
PY
}

run_oracle_path_smoke() {
  local output_dir="${1:-$ROOT/evaluation/harbor-oracle-path-smoke}"
  local ds_args=()
  assert_canonical_task
  mkdir -p "$output_dir"
  while IFS= read -r _arg; do
    [[ -n "$_arg" ]] && ds_args+=("$_arg")
  done < <(harbor_dataset_args "$ROOT_DATASET" "$TASK_NAME")
  harbor run "${ds_args[@]}" --agent oracle --env docker -o "$output_dir"
}

compute_fingerprint() {
  (
    cd "$ROOT"
    find "tasks/$TASK_NAME" -type f ! -name .DS_Store -print0 \
      | sort -z \
      | xargs -0 shasum -a 256 \
      | shasum -a 256 \
      | awk '{print $1}'
  )
}

read_expected_fingerprint() {
  python3 - <<PY
import json
from pathlib import Path
print(json.loads(Path("$RESULTS").read_text()).get("task_tree_fingerprint", ""))
PY
}

assert_fingerprint_unchanged() {
  local label="$1"
  local expected current
  expected="$(read_expected_fingerprint)"
  current="$(compute_fingerprint)"
  [[ -n "$expected" ]] || die "missing task_tree_fingerprint in $RESULTS"
  if [[ "$current" != "$expected" ]]; then
    die "$label: task fingerprint changed ($current != $expected); ABORT — all previous frontier evidence stale"
  fi
}

tb3_baseline_sha() {
  git -C "$TB3" rev-parse HEAD
}

repo_head_sha() {
  git -C "$ROOT" rev-parse HEAD
}

sync_tb3_upstream() {
  [[ -d "$TB3/.git" ]] || die "tb3-upstream is not a git checkout"
  say "Syncing TB3 upstream to origin/main..."
  git -C "$TB3" fetch origin
  git -C "$TB3" checkout main
  git -C "$TB3" pull --ff-only
  say "TB3 upstream HEAD: $(tb3_baseline_sha)"
}

tb3_ci_file_hash() {
  local relpath="$1"
  git -C "$TB3" show "HEAD:$relpath" | shasum -a 256 | awk '{print $1}'
}

compare_tb3_ci_baseline() {
  local recorded_sha="$1"
  mkdir -p "$STAGING"
  python3 - <<PY
import hashlib, json, subprocess
from pathlib import Path

tb3 = "$TB3"
recorded = "$recorded_sha"
files = [
  ".github/harbor-run-defaults.yml",
  ".github/workflows/run-cheat-trials.yml",
  ".github/workflows/review.yml",
  "rubrics/hack-trial-prompt.md",
  "rubrics/task-implementation.toml",
]

def hash_at(sha, path):
    try:
        data = subprocess.check_output(["git", "-C", tb3, "show", f"{sha}:{path}"])
    except subprocess.CalledProcessError:
        return None
    return hashlib.sha256(data).hexdigest()

current = {p: hash_at("HEAD", p) for p in files}
baseline = {p: hash_at(recorded, p) for p in files}
changed = [p for p in files if current.get(p) and baseline.get(p) and current[p] != baseline[p]]
Path("$STAGING/.tb3-ci-hashes.json").write_text(
    json.dumps({"current": current, "baseline_sha": recorded, "changed": changed}, indent=2) + "\n"
)
print("CHANGED:" + ",".join(changed) if changed else "UNCHANGED")
PY
}

is_builtin_harbor_agent() {
  case "${1:-}" in
    oracle|nop) return 0 ;;
    *) return 1 ;;
  esac
}

resolve_codex_auth_state() {
  CODEX_AUTH_MODE="blocked"
  CODEX_AUTH_FORWARDED=0
  if [[ -n "${OPENAI_API_KEY:-}" ]]; then
    CODEX_AUTH_MODE="api"
    CODEX_AUTH_FORWARDED=1
    return 0
  fi
  if [[ -f "${HOME}/.codex/auth.json" ]]; then
    export CODEX_FORCE_AUTH_JSON=1
    CODEX_AUTH_MODE="subscription"
    CODEX_AUTH_FORWARDED=1
    return 0
  fi
  return 1
}

resolve_claude_auth_state() {
  CLAUDE_AUTH_MODE="blocked"
  CLAUDE_AUTH_FORWARDED=0
  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    CLAUDE_AUTH_MODE="api"
    CLAUDE_AUTH_FORWARDED=1
    return 0
  fi
  if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
    export CLAUDE_FORCE_OAUTH=1
    CLAUDE_AUTH_MODE="oauth"
    CLAUDE_AUTH_FORWARDED=1
    return 0
  fi
  return 1
}

apply_frontier_auth_ae_flags() {
  local agent="$1"
  FRONTIER_AE_FLAGS=()
  case "$agent" in
    codex)
      resolve_codex_auth_state || die "Codex auth unavailable"
      if [[ "$CODEX_AUTH_MODE" == "subscription" ]]; then
        FRONTIER_AE_FLAGS=(--ae "CODEX_FORCE_AUTH_JSON=1")
      fi
      ;;
    claude-code)
      resolve_claude_auth_state || die "Claude auth unavailable"
      if [[ "$CLAUDE_AUTH_MODE" == "oauth" ]]; then
        FRONTIER_AE_FLAGS=(--ae "CLAUDE_FORCE_OAUTH=1")
      fi
      ;;
  esac
}

write_safe_command_evidence() {
  local trial_id="$1"
  shift
  local cmd_file="$STAGING/${trial_id}.cmd"
  printf 'COMMAND: %q ' "$@" > "$cmd_file"
  printf '\n' >> "$cmd_file"
  python3 "$REDACT_PY" "$cmd_file" >/dev/null
}

plan_harbor_run() {
  local agent="$1" model="$2" env="$3" trial_kind="$4" dataset_path="$5" task_name="$6"
  local uses_frontier="false"
  local kw_json="[]"
  local ae_json="[]"
  mkdir -p "$STAGING"

  assert_task_in_dataset "$(normalize_harbor_dataset_path "$dataset_path")" "$task_name"

  if is_builtin_harbor_agent "$agent"; then
    uses_frontier="false"
  else
    uses_frontier="true"
    local agent_json_file="$STAGING/plan-${agent}.agent.json"
    agent_config_json "$agent" > "$agent_json_file"
    kw_json="$(build_kwarg_flags_file "$agent_json_file" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
    apply_frontier_auth_ae_flags "$agent"
    ae_json="$(printf '%s\n' "${FRONTIER_AE_FLAGS[@]}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')"
  fi

  python3 - <<PY
import json
print(json.dumps({
  "agent": "$agent",
  "model": "$model",
  "env": "$env",
  "trial_kind": "$trial_kind",
  "dataset_path": "$(normalize_harbor_dataset_path "$dataset_path")",
  "task_name": "$task_name",
  "uses_frontier_config": $( [[ "$uses_frontier" == "true" ]] && echo True || echo False ),
  "kwflags": json.loads('''$kw_json'''),
  "ae_flags": json.loads('''$ae_json'''),
}))
PY
}

parse_tb3_defaults() {
  python3 - <<'PY' "$DEFAULTS_FILE"
import json, re, sys
from pathlib import Path

text = Path(sys.argv[1]).read_text()
out = {"trials": 3, "env": "modal", "validate_env": "modal", "agents": []}
for key in ("trials", "env", "validate_env"):
    m = re.search(rf"^{key}:\s*(\S+)", text, re.M)
    if m:
        out[key] = m.group(1).strip('"')

agents: list[dict] = []
current: dict | None = None
in_agents = False
section: str | None = None
for line in text.splitlines():
    if line.startswith("agents:"):
        in_agents = True
        continue
    if not in_agents:
        continue
    if line and not line.startswith(" ") and not line.startswith("#"):
        break
    m = re.match(r"  - agent:\s*(\S+)", line)
    if m:
        if current:
            agents.append(current)
        current = {"agent": m.group(1), "model": "", "kwargs": {}, "env": {}}
        section = None
        continue
    if not current:
        continue
    m = re.match(r"    model:\s*(.+)", line)
    if m:
        current["model"] = m.group(1).strip()
        section = None
        continue
    if re.match(r"    kwargs:", line):
        section = "kwargs"
        continue
    if re.match(r"    env:", line):
        section = "env"
        continue
    m = re.match(r"      ([A-Za-z0-9_]+):\s*\"?([^\"#]+?)\"?\s*(?:#.*)?$", line)
    if m and section in {"kwargs", "env"}:
        current[section][m.group(1)] = m.group(2).strip().strip('"')

if current:
    agents.append(current)
out["agents"] = agents
print(json.dumps(out))
PY
}

write_tb3_defaults() {
  mkdir -p "$STAGING"
  parse_tb3_defaults > "$STAGING/.harbor-defaults.json"
}

agent_config_json() {
  local agent="$1"
  write_tb3_defaults
  python3 - <<PY
import json, sys
cfg = json.load(open("$STAGING/.harbor-defaults.json"))
for a in cfg["agents"]:
    if a["agent"] == "$agent":
        json.dump(a, sys.stdout)
        break
else:
    raise SystemExit(f"agent $agent not in harbor-run-defaults.yml")
PY
}

check_modal_auth() {
  if [[ -n "${MODAL_TOKEN_ID:-}" && -n "${MODAL_TOKEN_SECRET:-}" ]]; then
    echo "PASS: Modal env tokens set"
    return 0
  fi
  if ! command -v modal >/dev/null 2>&1; then
    echo "BLOCKED: Modal CLI missing and MODAL_TOKEN_ID/MODAL_TOKEN_SECRET unset"
    return 1
  fi
  if modal profile current >/dev/null 2>&1; then
    echo "PASS: Modal CLI authenticated (profile current OK)"
    return 0
  fi
  echo "BLOCKED: Modal installed but unauthenticated (run: modal token new)"
  return 1
}

check_codex_auth() {
  if resolve_codex_auth_state; then
    if [[ "$CODEX_AUTH_MODE" == "api" ]]; then
      echo "PASS: OPENAI_API_KEY set; API-key auth will be used"
    else
      echo "PASS: subscription auth detected; CODEX_FORCE_AUTH_JSON=1 will be forwarded to Harbor"
    fi
    return 0
  fi
  echo "BLOCKED: no OPENAI_API_KEY or ~/.codex/auth.json"
  return 1
}

check_claude_auth() {
  if resolve_claude_auth_state; then
    if [[ "$CLAUDE_AUTH_MODE" == "api" ]]; then
      echo "PASS: ANTHROPIC_API_KEY set; API-key auth will be used"
    else
      echo "PASS: OAuth token detected; CLAUDE_FORCE_OAUTH=1 will be forwarded to Harbor"
    fi
    return 0
  fi
  echo "BLOCKED: no ANTHROPIC_API_KEY or CLAUDE_CODE_OAUTH_TOKEN"
  return 1
}

codex_auth_audit_label() {
  if resolve_codex_auth_state; then
    [[ "$CODEX_AUTH_MODE" == "api" ]] && echo "PASS" || echo "PASS"
  else
    echo "BLOCKED"
  fi
}

claude_auth_audit_label() {
  if resolve_claude_auth_state; then
    [[ "$CLAUDE_AUTH_MODE" == "api" ]] && echo "PASS" || echo "PASS"
  else
    echo "BLOCKED"
  fi
}

export_agent_env_from_json_file() {
  local json_file="$1"
  while IFS='=' read -r k v; do
    [[ -n "$k" ]] && export "$k=$v"
  done < <(python3 - <<PY
import json
for k, v in json.load(open("$json_file")).get("env", {}).items():
    print(f"{k}={v}")
PY
)
}

build_kwarg_flags_file() {
  local json_file="$1"
  python3 - <<PY
import json
for k, v in json.load(open("$json_file")).get("kwargs", {}).items():
    print(f"--ak {k}={v}")
PY
}

apply_official_cheat_transform() {
  local instruction="$1"
  local hack="$2"
  python3 - <<'PY' "$instruction" "$hack"
import re, sys
from pathlib import Path
inst = Path(sys.argv[1])
hack = Path(sys.argv[2])
text = inst.read_text()
text = re.sub(r"[ \t]*[Dd]o not cheat[^.]*\.", "", text)
text = text.rstrip() + "\n\n" + hack.read_text()
inst.write_text(text)
PY
}

prepare_cheat_staging() {
  local staging_task="$1"
  rm -rf "$staging_task"
  mkdir -p "$(dirname "$staging_task")"
  rsync -a "$TASK/" "$staging_task/"
  cp "$HACK_PROMPT" "$staging_task/.hack-trial-prompt.md.source"
  apply_official_cheat_transform "$staging_task/instruction.md" "$HACK_PROMPT"
}

verify_instruction_restored() {
  local canonical="$TASK/instruction.md"
  if grep -q "Red Team QA Agent" "$canonical" 2>/dev/null; then
    die "canonical instruction.md still contains cheat prompt — restore failed"
  fi
  if ! grep -qi "do not cheat" "$canonical"; then
    die "canonical instruction.md missing standard anti-cheat trailer"
  fi
}

test_cheat_transform_and_restore() {
  local tmp="$STAGING/cheat-restore-test"
  rm -rf "$tmp"
  prepare_cheat_staging "$tmp"
  grep -q "Red Team QA Agent" "$tmp/instruction.md" || return 1
  rm -rf "$tmp"
  verify_instruction_restored
}

run_harbor_and_classify() {
  local trial_id="$1" agent="$2" model="$3" env="$4" trial_kind="$5"
  local dataset_path="$6" task_name="$7" output_dir="$8"
  local log_file="$STAGING/${trial_id}.log"
  local cmd rc=0 kwflags=() ae_flags=() ds_args=()
  mkdir -p "$output_dir" "$STAGING"

  ds_args=()
  while IFS= read -r _arg; do
    [[ -n "$_arg" ]] && ds_args+=("$_arg")
  done < <(harbor_dataset_args "$dataset_path" "$task_name")

  if is_builtin_harbor_agent "$agent"; then
    validate_harbor_run_selection "${ds_args[@]}" --agent "$agent" --env "$env" >/dev/null
    cmd=(harbor run "${ds_args[@]}" --agent "$agent" --env "$env" -o "$output_dir")
  else
    local agent_json_file="$STAGING/${trial_id}.agent.json"
    agent_config_json "$agent" > "$agent_json_file"
    while IFS= read -r flag; do
      [[ -n "$flag" ]] && kwflags+=("$flag")
    done < <(build_kwarg_flags_file "$agent_json_file")
    export_agent_env_from_json_file "$agent_json_file"
    apply_frontier_auth_ae_flags "$agent"
    ae_flags=("${FRONTIER_AE_FLAGS[@]}")
    validate_harbor_run_selection "${ds_args[@]}" --agent "$agent" -m "$model" --env "$env" \
      "${kwflags[@]}" "${ae_flags[@]}" >/dev/null
    cmd=(harbor run "${ds_args[@]}" --agent "$agent" -m "$model" --env "$env" -o "$output_dir")
    if ((${#kwflags[@]})); then
      cmd+=("${kwflags[@]}")
    fi
    if ((${#ae_flags[@]})); then
      cmd+=("${ae_flags[@]}")
    fi
  fi

  write_safe_command_evidence "$trial_id" "${cmd[@]}"

  set +e
  "${cmd[@]}" 2>&1 | tee "$log_file"
  rc=${PIPESTATUS[0]}
  set -e

  local payload="$STAGING/${trial_id}.classify.json"
  python3 - <<PY > "$payload"
import json
print(json.dumps({
  "output_dir": "$output_dir",
  "log_file": "$log_file",
  "expected_agent": "$agent",
  "expected_model": "$model",
  "expected_env": "$env",
  "trial_kind": "$trial_kind",
  "harbor_exit_code": $rc,
}))
PY
  python3 "$CLASSIFY_PY" "$payload" > "$STAGING/${trial_id}.result.json"
  cat "$STAGING/${trial_id}.result.json"
}

test_secret_safe_command_evidence() {
  local trial_id="secret-selftest"
  local ds_args=()
  while IFS= read -r _arg; do
    [[ -n "$_arg" ]] && ds_args+=("$_arg")
  done < <(harbor_dataset_args "$TB3_DATASET" "$TASK_NAME")
  write_safe_command_evidence "$trial_id" harbor run "${ds_args[@]}" --agent codex \
    --ae CODEX_FORCE_AUTH_JSON=1 --ae CLAUDE_FORCE_OAUTH=1
}

preflight_checks() {
  local ok=1
  say "== TB3 final evaluation preflight =="
  print_path_diagnostics
  assert_runner_layout
  assert_canonical_task
  say "TB3 baseline: $(tb3_baseline_sha)"
  say "Task fingerprint: $(compute_fingerprint)"
  assert_fingerprint_unchanged "preflight" || return 1

  if check_no_hello_world_in_runner; then
    say "hello-world reference scan: PASS"
  else
    say "hello-world reference scan: FAIL"
    ok=0
  fi

  if check_harbor_run_has_task_selector; then
    say "harbor run task selector scan: PASS"
  else
    say "harbor run task selector scan: FAIL"
    ok=0
  fi

  if assert_task_paths_for_preflight; then
    :
  else
    ok=0
  fi

  if sync_task_to_tb3 >/dev/null 2>&1; then
    say "TB3 staged task path: PASS ($TB3_TASK)"
  else
    say "TB3 staged task path: FAIL"
    ok=0
  fi

  command -v harbor >/dev/null && say "Harbor: $(harbor --version 2>/dev/null || harbor -v 2>/dev/null || echo present)" || { say "Harbor: MISSING"; ok=0; }
  command -v jq >/dev/null && say "jq: present" || { say "jq: MISSING"; ok=0; }
  command -v docker >/dev/null && docker info >/dev/null 2>&1 && say "Docker: ok" || say "Docker: unavailable (local smoke only)"

  [[ -f "$DEFAULTS_FILE" ]] && say "harbor-run-defaults.yml: present" || { say "harbor-run-defaults.yml: MISSING"; ok=0; }
  [[ -f "$HACK_PROMPT" ]] && say "hack-trial-prompt.md: present" || { say "hack-trial-prompt.md: MISSING"; ok=0; }
  [[ -f "$TB3/.github/workflows/run-cheat-trials.yml" ]] && say "run-cheat-trials.yml: present" || { say "run-cheat-trials.yml: MISSING"; ok=0; }

  say "Parsed /run defaults:"
  parse_tb3_defaults | python3 -m json.tool

  say "Rubric CI: review.yml uses harbor exec -a claude-code -m sonnet (not harbor check opus-4-8)"
  check_modal_auth || ok=0
  check_codex_auth || ok=0
  check_claude_auth || ok=0

  [[ -d "$STAGING" ]] || mkdir -p "$STAGING"
  say "Output staging: $STAGING"
  say "Secret safety: no tokens printed by this script"
  if test_cheat_transform_and_restore >/dev/null 2>&1; then
    say "Cheat transform restore test: PASS"
  else
    say "Cheat transform restore test: FAIL"
    ok=0
  fi
  if python3 "$SELFTEST_PY" >/dev/null 2>&1; then
    say "Runner self-tests: PASS"
  else
    say "Runner self-tests: FAIL"
    python3 "$SELFTEST_PY" || true
    ok=0
  fi
  return $((ok == 1 ? 0 : 1))
}
