#!/usr/bin/env bash
# Minimal Harbor diagnostic: Oracle + Docker only, no paid/API agents.
# Forces LOCAL DATASET semantics (-p $ROOT/tasks --include-task-name).
# Aborts if resolved config uses registry tasks / hello-world / resolve_task_version path.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tb3_eval_lib.sh
source "$ROOT/scripts/lib/tb3_eval_lib.sh"

MODE="${1:-cli}"
OUTPUT="${HARBOR_SMOKE_OUTPUT:-$ROOT/evaluation/harbor-smoke-oracle}"

say "NOTE: Harbor Viewer \"Single task\" is registry-backed (resolve_task_version)."
say "      This smoke uses Local path / datasets only. Prefer this script over Viewer."
print_path_diagnostics
assert_runner_layout
assert_canonical_task

say "Harbor executable: $(command -v harbor)"
say "Harbor version: $(harbor --version 2>&1)"
say "Python: $(python3 --version 2>&1)"
say "Selected task name: $TASK_NAME"
say "Canonical dataset: $ROOT_DATASET"
say "Task name from task.toml: $(python3 - <<PY
import tomllib
print(tomllib.load(open("$TASK/task.toml", "rb"))["task"]["name"])
PY
)"

for path in "$TASK" "$TASK/task.toml" "$TASK/instruction.md" "$TASK/environment" "$TASK/solution" "$TASK/tests"; do
  [[ -e "$path" ]] || die "missing required task path: $path"
done

if rg -q 'hello-world' "$TASK/task.toml" "$TASK/instruction.md" 2>/dev/null; then
  die "task content references hello-world"
fi

check_no_hello_world_in_runner || die "stale hello-world in active runner scripts"

FP="$(compute_fingerprint)"
[[ "$FP" == "2c824a3e667a2b74740b97a086e6f5dcf7f5fb1c2db4396b5964cb2582bcba2f" ]] || \
  die "task fingerprint changed: $FP"

case "$MODE" in
  cli)
    say "Invocation mode: CLI local dataset + --include-task-name"
    ds_args=()
    while IFS= read -r _arg; do
      [[ -n "$_arg" ]] && ds_args+=("$_arg")
    done < <(harbor_dataset_args "$ROOT_DATASET" "$TASK_NAME")
    say "Preflight resolved config:"
    validate_harbor_run_selection "${ds_args[@]}" --agent oracle --env docker
    mkdir -p "$OUTPUT"
    # Fail fast if Harbor ever tries registry resolution in logs.
    set +e
    harbor run "${ds_args[@]}" --agent oracle --env docker -o "$OUTPUT" 2>&1 | tee "$OUTPUT/smoke.log"
    rc=${PIPESTATUS[0]}
    set -e
    if rg -q 'resolve_task_version' "$OUTPUT/smoke.log" 2>/dev/null; then
      die "FAIL — resolve_task_version reached (registry Single-task path)"
    fi
    [[ "$rc" -eq 0 ]] || die "harbor run failed (exit $rc)"
    ;;
  config)
    say "Invocation mode: JobConfig YAML (datasets[] local path)"
    CFG="$ROOT/config/harbor-lease-queue-fencing-oracle-docker.yaml"
    [[ -f "$CFG" ]] || die "missing config: $CFG"
    if rg -q 'harbor/hello-world|hello-world@latest' "$CFG"; then
      die "config references hello-world"
    fi
    if rg -n '^tasks:' "$CFG" >/dev/null; then
      die "config has top-level tasks: (registry); use datasets: only"
    fi
    RESOLVED="$(cd "$ROOT" && harbor run --print-config -c "$CFG" --agent oracle --env docker 2>&1)"
    assert_local_dataset_resolved "$RESOLVED" "$ROOT_DATASET"
    echo "$RESOLVED" | python3 -m json.tool | head -30
    mkdir -p "$OUTPUT"
    set +e
    (cd "$ROOT" && harbor run -c "$CFG" --agent oracle --env docker -o "$OUTPUT") 2>&1 | tee "$OUTPUT/smoke.log"
    rc=${PIPESTATUS[0]}
    set -e
    if rg -q 'resolve_task_version' "$OUTPUT/smoke.log" 2>/dev/null; then
      die "FAIL — resolve_task_version reached (registry Single-task path)"
    fi
    [[ "$rc" -eq 0 ]] || die "harbor run failed (exit $rc)"
    ;;
  *)
    die "usage: $0 [cli|config]"
    ;;
esac

verify_harbor_job_metadata "$OUTPUT"
say "HARBOR SMOKE: PASS"
