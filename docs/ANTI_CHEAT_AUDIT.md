# Anti-cheat audit (local)

**Fingerprint:** `2c824a3e667a2b74740b97a086e6f5dcf7f5fb1c2db4396b5964cb2582bcba2f`  
**TB3 baseline:** `9597744614a56cb5d7d52d22a9fa087b7249256c`  
**Note:** Local probes ≠ official TB3 `/cheat`.

## Read-only protection

Verifier hashes `/app/CONTRACT.md`, `/app/leaseq/clock.py`, `/app/leaseq/errors.py` from `tests/readonly_hashes.json` (verifier image only).

## Artifact scope

`artifacts = ["/app/leaseq", "/app/CONTRACT.md"]`. Tests use fresh temp roots only.

## Negative probes (Docker oracle agent with defective solutions)

| Probe | Reward | Status |
| ----- | ------ | ------ |
| no_implementation | 0.0 | PASS |
| memory_only | 0.0 | PASS |
| no_fencing | 0.0 | PASS |
| fence_reset_reopen | 0.0 | PASS |
| receipt_is_completion | 0.0 | PASS |
| wrong_worker_accepted | 0.0 | PASS |
| reopen_noop | 0.0 | PASS |
| hardcoded_visible | 0.0 | PASS |
| fence_skip_cheat | 0.0 | PASS |

Evidence under `evaluation/negative-probes-v2/`.

## Official `/cheat`

**SKIPPED_BY_USER / NOT RUN** — official Codex/Claude `/cheat` trials were not executed (subscription auth not completed; no paid API-key path). Modal Oracle/NOP validate **did** run (PASS).
