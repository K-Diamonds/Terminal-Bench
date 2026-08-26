#!/usr/bin/env bash
# Verify this checkout can satisfy Harbor Viewer's ./examples/tasks/hello-world default.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REQUIRED_COMMIT="dd8b2f06186d03d3934a3e3e7497d0a2b540b67e"
ok=1

say() { printf '%s\n' "$*"; }
fail() { say "FAIL: $*"; ok=0; }

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH:-}"

say "== Harbor local setup check =="
say "script-resolved ROOT=$ROOT"
say "pwd=$(pwd)"

if command -v git >/dev/null 2>&1; then
  toplevel="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  say "git rev-parse --show-toplevel=$toplevel"
  if [[ -n "$toplevel" && "$(cd "$toplevel" && pwd)" != "$ROOT" ]]; then
    fail "git toplevel does not match script ROOT"
  fi
  if git merge-base --is-ancestor "$REQUIRED_COMMIT" HEAD 2>/dev/null; then
    say "hello-world shim commit ancestor: PASS ($REQUIRED_COMMIT)"
  else
    say "Local checkout is stale."
    say "Run: git pull origin main"
    fail "missing ancestor $REQUIRED_COMMIT"
  fi
else
  fail "git not available"
fi

if [[ -f examples/tasks/hello-world/task.toml ]]; then
  say "examples/tasks/hello-world/task.toml: PASS"
else
  fail "missing examples/tasks/hello-world/task.toml"
fi

if [[ -f tasks/lease-queue-fencing/task.toml ]]; then
  say "tasks/lease-queue-fencing/task.toml: PASS"
else
  fail "missing tasks/lease-queue-fencing/task.toml"
fi

python3 - <<'PY'
from pathlib import Path
print("repo:", Path(".").resolve())
print("hello:", Path("examples/tasks/hello-world").resolve())
print("task:", Path("tasks/lease-queue-fencing").resolve())
# Relative default Harbor Viewer uses when cwd == repo root
rel = Path("./examples/tasks/hello-world").resolve()
print("viewer_default_rel:", rel)
print("viewer_default_exists:", (rel / "task.toml").is_file())
PY

if command -v harbor >/dev/null 2>&1; then
  say "harbor: $(command -v harbor) ($(harbor --version 2>&1))"
  # Preflight: resolved JobConfig must be local dataset, not registry Single task.
  # shellcheck source=scripts/lib/tb3_eval_lib.sh
  source "$ROOT/scripts/lib/tb3_eval_lib.sh"
  ds_args=()
  while IFS= read -r _arg; do
    [[ -n "$_arg" ]] && ds_args+=("$_arg")
  done < <(harbor_dataset_args "$ROOT_DATASET" "$TASK_NAME")
  if resolved="$(harbor run --print-config "${ds_args[@]}" --agent oracle --env docker 2>&1)" \
    && assert_local_dataset_resolved "$resolved" "$ROOT_DATASET"; then
    say "print-config local dataset preflight: PASS"
  else
    fail "print-config local dataset preflight failed"
  fi
  CFG="$ROOT/config/harbor-lease-queue-fencing-oracle-docker.yaml"
  if [[ -f "$CFG" ]]; then
    # Ignore comments when scanning for forbidden registry references.
    if rg -v '^\s*#' "$CFG" | rg -q 'harbor/hello-world|hello-world@latest'; then
      fail "JobConfig references hello-world"
    elif rg -n '^tasks:' "$CFG" >/dev/null; then
      fail "JobConfig has registry tasks: key"
    else
      say "JobConfig datasets-only: PASS"
    fi
  else
    fail "missing $CFG"
  fi
else
  fail "harbor not on PATH"
fi

# Prefer CLI smoke for evaluation; Viewer must not promote hello-world evidence.
if [[ -f evaluation/results.json ]]; then
  if rg -qi 'hello-world' evaluation/results.json 2>/dev/null; then
    fail "evaluation/results.json contains hello-world — remove before submission"
  else
    say "evaluation/results.json hello-world free: PASS"
  fi
fi

if [[ "$ok" -eq 1 ]]; then
  say "HARBOR LOCAL CHECK: PASS"
  exit 0
fi
say "HARBOR LOCAL CHECK: FAIL"
exit 1
