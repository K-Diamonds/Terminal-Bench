# TB3 Requirements Audit (refresh)

**Audit date (UTC):** 2026-08-25T20:00:00Z  
**Upstream remote:** `https://github.com/harbor-framework/terminal-bench-3`  
**TB3 baseline SHA (after `git fetch` + `git pull --ff-only`):** `9597744614a56cb5d7d52d22a9fa087b7249256c`  
**Authority:** executable CI/scripts on this SHA beat prose docs.

---

## Hiring vs current TB3 `/run` configuration

| Dimension | Hiring email examples | Current TB3 `.github/harbor-run-defaults.yml` @ `9597744` | What we use |
| --------- | --------------------- | -------------------------------------------------------- | ----------- |
| Agents/models/kwargs | Codex `openai/gpt-5.6-sol` `xhigh`; Claude `anthropic/claude-opus-5` `max` | Identical + `CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000` | Match TB3 defaults |
| Trials | 3 per agent | `trials: 3` | 3 valid per agent |
| `/run` + `/cheat` env | Examples often show `--env docker` | **`env: modal`** | **Final CI-equivalent evidence must use Modal** |
| `/validate` env | docker locally | **`validate_env: modal`** | Local docker OK for smoke; Modal for CI-equivalent validate when secrets exist |
| Cheat success rule | Hiring: any nonzero reward = fail | TB3 may treat reward 1 as “solved or hacked” | Hiring stricter: cheat reward must be **0** |

**Discrepancy (explicit):** Local development validation uses **Docker**. Final CI-equivalent `/run` and `/cheat` evidence must use **Modal** per current TB3 defaults. Docker-only frontier trials do **not** satisfy current CI equivalence.

---

## Upstream deltas since previous baseline `45e8192`

Material for this task:

- `checks/check-task-fields.sh` now requires task `README.md` sections: Difficulty / Solution / Verification explanation + Relevant experience.
- `docs/task-template.toml` uses `network_mode = "public"` and no `allow_internet` key.
- `harbor-run-defaults.yml` still `env: modal` / `validate_env: modal` with the same agent pairs.
- Harbor pin in `/run`+`/cheat` workflows remains `0.14.0`.

---

## `allow_internet` policy (doc vs CI)

| Source | Rule |
| ------ | ---- |
| `docs/task-template.toml` @ HEAD | `network_mode = "public"` (no allow_internet key) |
| `checks/check-allow-internet.sh` | fails if `allow_internet = false` |
| `checks/check-no-allow-internet-true.sh` | fails if `allow_internet = true` |

**Decision:** omit `allow_internet` entirely; set `network_mode = "public"`.

---

## Static checks inventory (22)

Command: `for check in checks/check-*.sh; do bash "$check" tasks/lease-queue-fencing; done`  
Upstream SHA: `9597744`  
Log: `evaluation/static-checks-9597744.log`

---

## Contract → verifier mapping

| Contract requirement | Verifier coverage |
| -------------------- | ----------------- |
| enqueue durable; DuplicateMessageError | `test_basic.py::test_duplicate_enqueue`, `test_recovery.py::test_durability_after_each_mutation` |
| claim prefers unleased over expired | `test_fencing.py::test_prefer_unleased_over_expired` |
| steal lex smallest expired | `test_fencing.py::test_steal_lexicographically_smallest_expired` |
| claim None when nothing claimable | `test_basic.py::test_claim_none_when_empty` |
| lease_ms > 0 | `test_basic.py::test_lease_ms_must_be_positive` |
| every claim bumps fence high-water | `test_fencing.py::test_every_claim_bumps_fence` |
| commit: wrong worker | `test_fencing.py::test_commit_wrong_worker_and_fence` |
| commit: wrong fence | `test_fencing.py::test_commit_wrong_worker_and_fence` |
| commit: expired | `test_fencing.py::test_expired_lease_cannot_commit` |
| commit: identical / conflict receipt | `test_fencing.py::test_idempotent_and_conflicting_receipt` |
| receipt ≠ completion | `test_basic.py::test_receipt_does_not_complete` |
| ack: requires receipt | `test_basic.py::test_ack_requires_receipt` |
| ack: wrong worker / fence / expiry | `test_fencing.py::test_ack_wrong_worker_fence_and_expiry` |
| ack: stale after steal | `test_fencing.py::test_stale_fence_after_steal` |
| ack: idempotent with receipt fence | `test_fencing.py::test_idempotent_ack_with_receipt_fence` |
| reopen() restores pending/leases/receipts/hwm | `test_recovery.py::test_explicit_reopen_restores_state`, `test_reopen_restores_active_lease_fields` |
| constructor recovers like reopen | `test_recovery.py::test_constructor_recovers_like_reopen` |
| durability after enqueue/claim/commit/ack | `test_recovery.py::test_durability_after_each_mutation` |
| torn trailing record | `test_recovery.py::test_torn_trailing_record_ignored` |
| compact preserves state + high-water | `test_recovery.py::test_compact_preserves_state_and_high_water` |
| torn trailing after compact | `test_recovery.py::test_torn_compact_does_not_lose_prior_state` |
| multi-instance coherence | `test_recovery.py::test_peer_instance_observes_mutations` |
| multi-process fencing | `test_concurrency.py::test_process_peer_claim_fencing` |
| completed never pending; not reclaimable | `test_recovery.py::test_completed_not_pending_after_reopen`, `test_basic.py::test_completed_not_reclaimable` |
| deep-copy receipts/payloads | `test_basic.py::test_payload_and_receipt_detachment` |
| concurrent claim one item | `test_concurrency.py::test_concurrent_claim_single_message` |
| stale vs replacement worker | `test_concurrency.py::test_barrier_steal_vs_stale_commit` |
| concurrent duplicate receipt commits | `test_concurrency.py::test_concurrent_duplicate_receipt_commits` |
| read-only CONTRACT/clock/errors | hash gate in `tests/test.sh` via `readonly_hashes.json` |

---

## Difficulty assessment (pre-frontier)

| Question | Assessment |
| -------- | ---------- |
| Would an expert need several hours? | Yes — multi-instance locking, torn writes, compaction high-water, fencing across steals. |
| Can a frontier model rewrite `store.py` from CONTRACT alone? | **Still a risk.** Contract is semantic but complete; a strong model may implement it directly. |
| Strong enough for GPT-5.6 Sol xhigh / Claude Opus 5 max 0/3? | **UNPROVEN** until Modal trials. Do not claim failure yet. |

---

## Artifacts

`artifacts = ["/app/leaseq", "/app/CONTRACT.md"]`  
Verifier always builds **fresh** temp roots; agent journals are not trusted.

---

## Evidence model

| Field | Meaning |
| ----- | ------- |
| `task_content_commit` | Last commit materially changing `tasks/lease-queue-fencing/` |
| `task_tree_fingerprint` | SHA256 fingerprint of task files — binds all trial evidence |
| `tb3_baseline_sha` | Upstream TB3 commit for checks/defaults |
| `evidence_generated_from_commit` | Commit when Harbor evidence was produced |

**Do not** record `repository_head_sha` in `results.json` — updating evidence docs creates a new HEAD and makes that field stale.

Documentation-only changes outside the task tree do not invalidate trials. Material task changes invalidate all frontier/cheat evidence.
