#!/usr/bin/env bash
# Reliable ONE-TASK runner for the local unpublished TB3 task.
# Always uses Harbor local dataset semantics (-p $DATASET --include-task-name).
# Never uses Viewer "Single task" / registry resolve_task_version.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tb3_eval_lib.sh
source "$ROOT/scripts/lib/tb3_eval_lib.sh"

TASK_NAME="lease-queue-fencing"
DATASET="$ROOT/tasks"
EXPECTED_FP="2c824a3e667a2b74740b97a086e6f5dcf7f5fb1c2db4396b5964cb2582bcba2f"

AGENT="${1:-}"
ENV_BACKEND="${2:-}"
STAMP="$(date -u +%Y-%m-%d__%H-%M-%S)"
OUTPUT="$ROOT/evaluation/single-${AGENT:-unknown}-${STAMP}"
LOG_FILE=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/run_one.sh oracle docker
  bash scripts/run_one.sh nop docker
  bash scripts/run_one.sh codex modal
  bash scripts/run_one.sh claude-code modal

Always runs local dataset semantics via harbor_dataset_args
($ROOT/tasks + --include-task-name lease-queue-fencing).

Do NOT use Harbor Viewer "Single task" — that is registry-only.
EOF
}

fail_registry() {
  die "FAIL — REGISTRY TASK MODE ACCIDENTALLY USED${1:+ ($1)}"
}

scan_log_for_registry() {
  local log="$1"
  [[ -f "$log" ]] || return 0
  if rg -qi 'resolve_task_version|harbor/hello-world|Task version not found' "$log"; then
    fail_registry "see $log"
  fi
}

assert_task_layout() {
  [[ -f "$DATASET/$TASK_NAME/task.toml" ]] || die "missing $DATASET/$TASK_NAME/task.toml"
  [[ -f "$DATASET/$TASK_NAME/instruction.md" ]] || die "missing $DATASET/$TASK_NAME/instruction.md"
}

preflight_resolved_config() {
  local -a preview=("$@")
  local resolved
  resolved="$(harbor run --print-config "${preview[@]}" 2>&1)" || die "harbor run --print-config failed"
  assert_local_dataset_resolved "$resolved" "$DATASET"
  if echo "$resolved" | rg -qi 'resolve_task_version|harbor/hello-world|hello-world@latest'; then
    fail_registry "in --print-config output"
  fi
  echo "$resolved" | python3 -m json.tool 2>/dev/null | head -20 || echo "$resolved" | head -20
}

verify_run_metadata() {
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
    raise SystemExit("FAIL — hello-world in result metadata")
name = data.get("task_name") or ""
path = str((data.get("task_id") or {}).get("path") or "")
if "lease-queue-fencing" not in name and "lease-queue-fencing" not in path:
    raise SystemExit(f"FAIL — executed task is not lease-queue-fencing: name={name!r} path={path!r}")
reward = None
vr = data.get("verifier_result") or {}
if vr.get("rewards"):
    reward = next(iter(vr["rewards"].values()))
print(f"Task executed: {name}")
print(f"task_path={path}")
print(f"reward={reward}")
PY
}

require_tb3_defaults() {
  [[ -f "$DEFAULTS_FILE" ]] || die "missing TB3 defaults: $DEFAULTS_FILE (clone/sync tb3-upstream)"
}

main() {
  export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH:-}"
  command -v harbor >/dev/null 2>&1 || die "harbor not found on PATH"

  case "$AGENT" in
    oracle|nop|codex|claude-code) ;;
    ""|-h|--help) usage; exit 0 ;;
    *) usage; die "unknown agent: $AGENT" ;;
  esac
  case "$ENV_BACKEND" in
    docker|modal) ;;
    *) usage; die "unknown environment: ${ENV_BACKEND:-<missing>} (use docker|modal)" ;;
  esac

  cd "$ROOT"
  assert_task_layout
  assert_canonical_task

  local fp
  fp="$(compute_fingerprint)"
  [[ "$fp" == "$EXPECTED_FP" ]] || die "task fingerprint changed: $fp"

  mkdir -p "$OUTPUT" "$STAGING"
  LOG_FILE="$OUTPUT/run_one.log"

  say "SINGLE LOCAL TASK RUNNER"
  say ""
  say "Resolved repo: $ROOT"
  say "Dataset: $DATASET"
  say "Selected task: $TASK_NAME"
  say "Agent: $AGENT"
  say "Environment: $ENV_BACKEND"
  say "Output: $OUTPUT"
  say ""

  local -a ds_args=() cmd=() preview=() kwflags=() ae_flags=()
  local model="" agent_json_file=""

  while IFS= read -r _arg; do
    [[ -n "$_arg" ]] && ds_args+=("$_arg")
  done < <(harbor_dataset_args "$DATASET" "$TASK_NAME")

  if is_builtin_harbor_agent "$AGENT"; then
    preview=("${ds_args[@]}" --agent "$AGENT" --env "$ENV_BACKEND")
    say "Preflight resolved config:"
    preflight_resolved_config "${preview[@]}"
    cmd=(harbor run "${ds_args[@]}" --agent "$AGENT" --env "$ENV_BACKEND" -o "$OUTPUT")
  else
    require_tb3_defaults
    case "$AGENT" in
      codex) check_codex_auth >/dev/null || die "Codex auth blocked" ;;
      claude-code) check_claude_auth >/dev/null || die "Claude auth blocked" ;;
    esac
    if [[ "$ENV_BACKEND" == "modal" ]]; then
      check_modal_auth >/dev/null || die "Modal auth blocked"
    fi

    agent_json_file="$OUTPUT/${AGENT}.agent.json"
    agent_config_json "$AGENT" > "$agent_json_file"
    model="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["model"])' "$agent_json_file")"
    [[ -n "$model" ]] || die "empty model for $AGENT in harbor-run-defaults.yml"
    say "TB3 defaults model: $model (secrets not printed)"

    while IFS= read -r flag; do
      [[ -n "$flag" ]] && kwflags+=("$flag")
    done < <(build_kwarg_flags_file "$agent_json_file")
    export_agent_env_from_json_file "$agent_json_file"
    apply_frontier_auth_ae_flags "$AGENT"
    ae_flags=("${FRONTIER_AE_FLAGS[@]}")

    preview=("${ds_args[@]}" --agent "$AGENT" -m "$model" --env "$ENV_BACKEND")
    if ((${#kwflags[@]})); then preview+=("${kwflags[@]}"); fi
    if ((${#ae_flags[@]})); then preview+=("${ae_flags[@]}"); fi

    say "Preflight resolved config:"
    preflight_resolved_config "${preview[@]}"

    cmd=(harbor run "${ds_args[@]}" --agent "$AGENT" -m "$model" --env "$ENV_BACKEND" -o "$OUTPUT")
    if ((${#kwflags[@]})); then cmd+=("${kwflags[@]}"); fi
    if ((${#ae_flags[@]})); then cmd+=("${ae_flags[@]}"); fi
  fi

  say ""
  say "Registry mode: DISABLED"
  say "Local dataset mode: PASS"
  say "Resolved config: PASS"
  say "hello-world reference: ABSENT"
  say ""

  # Redacted command evidence only.
  {
    printf 'COMMAND:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
  } > "$OUTPUT/command.raw.txt"
  python3 "$REDACT_PY" "$OUTPUT/command.raw.txt" > "$OUTPUT/command.redacted.txt" 2>/dev/null \
    || cp "$OUTPUT/command.raw.txt" "$OUTPUT/command.redacted.txt"
  rm -f "$OUTPUT/command.raw.txt"

  set +e
  "${cmd[@]}" 2>&1 | tee "$LOG_FILE"
  local rc=${PIPESTATUS[0]}
  set -e

  scan_log_for_registry "$LOG_FILE"
  [[ "$rc" -eq 0 ]] || die "harbor run failed (exit $rc)"

  local meta reward=""
  meta="$(verify_run_metadata "$OUTPUT")"
  say "$meta"
  reward="$(echo "$meta" | sed -n 's/^reward=//p' | tail -1)"

  say ""
  say "resolve_task_version reached: NO"
  if [[ "$AGENT" == "oracle" ]]; then
    say "Oracle started: PASS"
    say "Oracle reward: ${reward:-unknown}"
    python3 -c "import sys; r=sys.argv[1]; sys.exit(0 if r not in ('', 'None') and float(r) >= 1.0 else 1)" "${reward:-}" \
      || die "oracle reward expected 1.0, got ${reward:-empty}"
  else
    say "${AGENT} started: PASS"
    say "Reward: ${reward:-n/a}"
  fi
  say "Task executed: lease-queue-fencing"
  say "Task fingerprint unchanged: PASS"

  local safe="NO"
  if [[ -f "$DEFAULTS_FILE" ]] \
    && check_modal_auth >/dev/null 2>&1 \
    && check_codex_auth >/dev/null 2>&1 \
    && check_claude_auth >/dev/null 2>&1; then
    safe="YES"
  fi
  say "SAFE FOR FRONTIER RUNS: $safe"
}

main "$@"
