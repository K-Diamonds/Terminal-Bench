#!/usr/bin/env bash
# Start Harbor Viewer with cwd = repository root so the Viewer UI default
# ./examples/tasks/hello-world resolves to this repo (not $HOME/examples/...).
#
# Viewer "Single task" is REGISTRY-backed (resolve_task_version) — never use it
# for the local unpublished lease-queue-fencing task.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

REQUIRED_COMMIT="dd8b2f06186d03d3934a3e3e7497d0a2b540b67e"
HELLO="$ROOT/examples/tasks/hello-world"
TASK="$ROOT/tasks/lease-queue-fencing"
JOBS_DIR="${HARBOR_VIEW_JOBS_DIR:-$ROOT/evaluation/harbor-viewer-jobs}"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

export PATH="${HOME}/.local/bin:/opt/homebrew/bin:${PATH:-}"

command -v harbor >/dev/null 2>&1 || die "harbor not found on PATH"

if ! git -C "$ROOT" merge-base --is-ancestor "$REQUIRED_COMMIT" HEAD 2>/dev/null; then
  echo "Local checkout is stale."
  echo "Run: git pull origin main"
  exit 1
fi

[[ -f "$HELLO/task.toml" ]] || die "missing Harbor compatibility task: $HELLO/task.toml"
[[ -f "$TASK/task.toml" ]] || die "missing TB3 task: $TASK/task.toml"

mkdir -p "$JOBS_DIR"

echo "Repository root: $ROOT"
echo "Current working directory: $(pwd)"
echo "Harbor executable: $(command -v harbor)"
echo "Harbor version: $(harbor --version 2>&1)"
echo "Default Viewer Local-path fallback: $HELLO"
echo "Real TB3 task: $TASK"
echo ""
echo "Invariant: pwd must equal repository root before Viewer starts."
[[ "$(pwd)" == "$ROOT" ]] || die "pwd is not repository root"
echo "pwd == repository root: OK"
echo ""
echo "IMPORTANT:"
echo "Choose \"Local path\", NOT \"Single task\"."
echo ""
echo "Path:"
echo "$ROOT/tasks"
echo ""
echo "Include task name:"
echo "lease-queue-fencing"
echo ""
echo "Agent: oracle (smoke) · Environment: docker"
echo ""
echo "DO NOT choose \"Single task\"."
echo "\"Single task\" resolves a registered Harbor task by name/ref"
echo "(resolve_task_version) and will fail for unpublished local tasks."
echo "examples/tasks/hello-world only avoids a Local-path FileNotFoundError;"
echo "it does NOT register harbor/hello-world in the Harbor task registry."
echo ""
echo "Preferred CLI (no Viewer): bash scripts/harbor_smoke.sh"
echo "Starting: harbor view \"$JOBS_DIR\" --jobs"
echo ""

exec harbor view "$JOBS_DIR" --jobs "$@"
