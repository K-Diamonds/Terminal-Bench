# Final evaluation authentication

Frontier agent runs need subscription authentication (hiring instructions: API payment is not required).

## Already completed on this submission

| Gate | Status |
| ---- | ------ |
| Modal Oracle | PASS — reward 1.0 |
| Modal NOP | PASS — reward 0.0 |

Modal workspace auth was configured locally for those runs. Do not treat Modal validate as NOT RUN/BLOCKED in current evidence.

## Still required for remaining hiring gates

| Gate | Status in evidence | How to unblock (subscription preferred) |
| ---- | ------------------ | --------------------------------------- |
| Implementation rubric | SKIPPED_BY_USER | `claude setup-token` → export `CLAUDE_CODE_OAUTH_TOKEN` + `CLAUDE_FORCE_OAUTH=1` for Harbor (`harbor exec` / check). Prior API-key attempt failed: credit balance too low. |
| Codex standard ×3 + `/cheat` | SKIPPED_BY_USER / NOT RUN | `codex login` → `~/.codex/auth.json` + Harbor `--ae CODEX_FORCE_AUTH_JSON=1` |
| Claude standard ×3 + `/cheat` | SKIPPED_BY_USER / NOT RUN | Same Claude OAuth as rubric + `CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000` |

See `evaluation/results.json` and the README validation table (`submission_ready: false`).

Verify (no secrets printed):

```bash
python3 -c 'import os; print({k: bool(os.getenv(k)) for k in ["ANTHROPIC_API_KEY","OPENAI_API_KEY","MODAL_TOKEN_ID","MODAL_TOKEN_SECRET","CLAUDE_CODE_OAUTH_TOKEN"]})'
[[ -f "$HOME/.codex/auth.json" ]] && echo codex_auth=present || echo codex_auth=absent
modal profile current
```

## Run sequence (after auth)

From repo root with `tb3-upstream` synced:

```bash
export PATH="$HOME/.local/bin:/opt/homebrew/bin:$PATH"
bash scripts/run_final_eval.sh
bash scripts/pre_submit.sh
```

`run_final_eval.sh` verifies the task fingerprint has not changed, then runs rubric → Modal oracle/nop → Codex×3 → Claude×3 → cheat×2 using current TB3 defaults.

## Evidence invariants

- **Task evidence** is keyed by `task_content_commit` + `task_tree_fingerprint`.
- **Documentation-only** commits outside `tasks/lease-queue-fencing/` do **not** invalidate trials.
- **Material task changes** invalidate all frontier/cheat evidence — recompute fingerprint and rerun everything.
