# Terminal-Bench 3 Hiring Submission

## Overview

| Field | Value |
| ----- | ----- |
| Task | `lease-queue-fencing` |
| Path | `tasks/lease-queue-fencing` |
| Domain | Software / Systems |

Repair a durable visibility-lease work queue so fencing, idempotent receipts, torn-write recovery, compaction, and multi-instance coherence match `/app/CONTRACT.md`.

## Repository baseline

| Item | Value |
| ---- | ----- |
| Upstream TB3 | https://github.com/harbor-framework/terminal-bench-3 |
| Tested TB3 `main` SHA (static baseline) | `9597744614a56cb5d7d52d22a9fa087b7249256c` |
| Current synced TB3 `main` SHA | `d4df6e5744d6fee3ad0ee411c8b50c95b125a251` |
| Harbor (local + Modal validate) | `0.18.0` |
| TB3 `/run`+`/cheat` Harbor pin in CI | `0.14.0` (workflow pin; documented) |
| Local validate backend | **Docker** (development) |
| TB3 default `/run`+`/cheat` backend | **Modal** (`env: modal` in `.github/harbor-run-defaults.yml`) |
| TB3 default `/validate` backend | **Modal** (`validate_env: modal`) |

### Environment policy (explicit)

| Use case | Backend | Notes |
| -------- | ------- | ----- |
| Local development (Oracle / NOP / debugging) | **Docker** | Acceptable for smoke and iteration |
| Final CI-equivalent frontier `/run` and `/cheat` | **Modal** + current agent defaults | Required; Docker frontier trials do **not** reproduce current TB3 CI |

Hiring email Docker examples are not the source of truth when they disagree with current TB3 CI defaults.

Current `/run` defaults (from upstream `harbor-run-defaults.yml`):

- `trials: 3`
- `env: modal`
- Claude Code: `anthropic/claude-opus-5`, `reasoning_effort=max`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000`
- Codex: `openai/gpt-5.6-sol`, `reasoning_effort=xhigh`

## Validation results

Statuses are executed evidence only. Terminology: **PASS** / **FAIL** / **BLOCKED** / **SKIPPED_BY_USER** / **NOT RUN**.

| Gate | Expected | Actual | Status |
| ---- | -------- | ------ | ------ |
| Static checks (22) | exit 0 | exit 0 | PASS |
| Implementation rubric | all applicable PASS | API credit balance too low on attempt; subscription OAuth not completed | SKIPPED_BY_USER |
| Docker build | success | success | PASS |
| Oracle ×5 (Docker) | reward 1 | 1.0 ×5 | PASS |
| NOP (Docker) | reward 0 | 0.0 | PASS |
| Negative probes (9) | all reward 0 | 0.0 ×9 | PASS |
| Modal Oracle (CI-equivalent validate) | reward 1 | 1.0 | PASS |
| Modal NOP (CI-equivalent validate) | reward 0 | 0.0 | PASS |
| Codex standard ×3 (Modal) | reward 0 valid | no trials | SKIPPED_BY_USER / NOT RUN |
| Claude standard ×3 (Modal) | reward 0 valid | no trials | SKIPPED_BY_USER / NOT RUN |
| Codex `/cheat` (Modal) | reward 0 | no trials | SKIPPED_BY_USER / NOT RUN |
| Claude `/cheat` (Modal) | reward 0 | no trials | SKIPPED_BY_USER / NOT RUN |

Machine-readable: `evaluation/results.json`  
Task fingerprint: `evaluation/task-fingerprint.sha`  
**SUBMISSION READY: NO** (`submission_ready: false`)

### Evidence model (do not stamp `repository_head_sha`)

| Field | Meaning |
| ----- | ------- |
| `task_content_commit` | Last git commit that materially changed `tasks/lease-queue-fencing/` |
| `task_tree_fingerprint` | SHA256 over sorted task file hashes — **the proof anchor** |
| `tb3_baseline_sha` | Upstream TB3 commit used for checks/defaults |
| `evidence_generated_from_commit` | Commit when recorded Harbor evidence was produced |

Documentation-only commits outside the task tree **do not** invalidate trials. Material task changes **do** — recompute fingerprint and rerun all evaluation.

See `docs/FINAL_EVAL_AUTH.md` for rubric/Modal/frontier auth setup.

## Contributor metadata

From local git config: `Karla` / `karlaofferman@gmail.com`.

## `allow_internet`

Current TB3 CI **forbids** both `allow_internet = true` and `= false`. Task **omits** the key (open-internet via Harbor default / `network_mode = "public"`).

## Harbor Viewer (working directory)

Harbor Viewer 0.18.0 hardcodes New run defaults:

- Local path: `./examples/tasks/hello-world`
- Dataset: `terminal-bench@2.0`
- Single task: `harbor/hello-world`

Those paths are resolved relative to the **process working directory** of `harbor view`, not the repo root automatically.

**Do not start Harbor Viewer from your home directory.**

```text
Correct:
cd <Terminal-Bench repo>
bash scripts/check_harbor_local.sh
bash scripts/start_harbor_view.sh

Incorrect:
cd ~
harbor view
```

### IMPORTANT: Viewer “Single task” is registry-only

Harbor Viewer source kinds are:

| Kind | Label | Resolves via |
| ---- | ----- | ------------ |
| `path` | Local path | Local filesystem (`datasets[].path` / local task dirs) |
| `dataset` | Dataset | Named/remote dataset |
| `task` | Single task | **Harbor registry** (`resolve_task_version(org, name, ref)`) |

**DO NOT choose “Single task” for `lease-queue-fencing`.**

“Single task” looks up a registered Harbor package (`harbor/hello-world@latest`, etc.). Our TB3 task is local and unpublished — registry lookup cannot see it and fails with `Task version not found`.

The shim at `examples/tasks/hello-world/` only prevents the default **Local path** from throwing `FileNotFoundError` when cwd is the repo root. It does **not** register `harbor/hello-world` in Harbor’s task registry and cannot fix Viewer “Single task”.

**To run exactly one local task, use `scripts/run_one.sh`.
Do NOT use Harbor Viewer's "Single task" source. That source is for
registered Harbor tasks, not local filesystem tasks.**

```bash
bash scripts/run_one.sh oracle docker
bash scripts/run_one.sh nop docker
# Frontier (requires TB3 defaults + auth; Modal for CI-equivalent):
# bash scripts/run_one.sh codex modal
# bash scripts/run_one.sh claude-code modal
```

Also available: `bash scripts/harbor_smoke.sh` (Oracle-only diagnostic).

### Viewer New run fields for the real task (ONLY correct mode)

After `bash scripts/start_harbor_view.sh` (jobs mode), open **New run** and set:

| Field | Value |
| ----- | ----- |
| Source kind | **Local path** (never “Single task”) |
| Path | `<absolute-repo-root>/tasks` |
| Include task name | `lease-queue-fencing` |
| Agent | `oracle` (smoke only) |
| Environment | `docker` |

Do **not** leave Path as `./examples/tasks/hello-world`. Hello-world results must never enter `evaluation/results.json`.

JobConfig equivalent (local dataset semantics only):

```bash
harbor run -c config/harbor-lease-queue-fencing-oracle-docker.yaml --agent oracle --env docker
```

## Reproduction (local Docker)

```bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
git clone https://github.com/harbor-framework/terminal-bench-3.git tb3-upstream
cd tb3-upstream && git checkout 9597744614a56cb5d7d52d22a9fa087b7249256c
rsync -a ../tasks/lease-queue-fencing/ tasks/lease-queue-fencing/
for check in checks/check-*.sh; do bash "$check" tasks/lease-queue-fencing; done
# Local dataset + include filter (not registry Single task)
harbor run -p tasks --include-task-name lease-queue-fencing --agent oracle --env docker
harbor run -p tasks --include-task-name lease-queue-fencing --agent nop --env docker
bash ../scripts/pre_submit.sh
```

## Frontier / cheat (only after local gates + credentials)

Use exact current TB3 defaults (`env: modal`, agents/models/kwargs/env from `.github/harbor-run-defaults.yml`). Do **not** treat Docker frontier runs as final CI-equivalent evidence.

## Design docs

- `docs/TASK_DESIGN.md`
- `docs/TB3_REQUIREMENTS_AUDIT.md`
- `docs/ANTI_CHEAT_AUDIT.md`
- `docs/FRONTIER_FAILURE_ANALYSIS.md`

## Submission readiness

**SUBMISSION READY: NO**

Still required for a complete TB3 hiring matrix (not yet available here): implementation rubric **PASS**, Modal-backed Codex/Claude 3+3 **valid model failures** (reward 0), and official `/cheat` reward 0 on the final task fingerprint.
