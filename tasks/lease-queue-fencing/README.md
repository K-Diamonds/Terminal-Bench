# lease-queue-fencing (reviewer notes)

Optional reviewer context (not shown to the agent).

## Difficulty explanation

The core difficulty is making lease fencing and exactly-once side effects hold under concurrent queue instances, crash recovery, torn durable writes, and crash-safe compaction — not implementing a single-threaded happy path. Correct behavior requires globally monotonic fencing tokens across steals, restarts, and compaction; stale workers cannot commit or ack after a steal; receipts are durable and idempotent without marking completion; incomplete trailing durable records must not corrupt earlier state; and multiple `WorkQueue` instances on one durable root must not make stale fencing decisions from private memory.

## Solution explanation

Keep a single durable log under the queue root, guarded by cross-instance mutual exclusion. On every mutating call, refresh state from durable storage, validate the active lease (worker, fence, unexpired deadline) before receipt commit or ack, and assign each successful claim a fencing token strictly greater than every previously issued token for that root. Persist each successful mutation so a crash or a peer instance observes it; tolerate a truncated trailing record after crash without dropping earlier complete records. Treat receipts as durable but distinct from completion; only ack moves a message to completed. Compaction must rewrite durable storage while preserving semantic state including the fencing high-water.

## Verification explanation

The separate verifier uploads only `/app/leaseq` and `/app/CONTRACT.md`, hashes the three read-only files, and runs behavioral pytest modules as an unprivileged user against fresh temporary roots created by the verifier (never agent-created journals). Schedules cover claim selection, full fence/worker/expiry semantics for commit and ack, explicit reopen, durability after each mutation, torn trailing records, compaction, multi-instance/process coherence, and deterministic concurrency via barriers and the logical clock. Reward is binary; CTRF records per-test outcomes.

## Relevant experience

Backend engineer with production experience on lease-based work queues, visibility-timeout consumers, fencing-token protections for settlement side effects, and crash-safe durable logs.

## Intent

Repair a durable visibility-lease work queue so fencing tokens gate side-effect commits and acks under lease steal, crash recovery, and compaction.

## Bug map (oracle-only)

1. Steal reuses fence instead of bumping high-water.
2. `commit_side_effect` / `ack` skip fence validation.
3. Receipts not journaled (lost on crash).
4. Recovery treats receipts as completion (skips ack).
5. Fence high-water not restored on reopen.
6. No cross-instance lock / peer refresh; torn trailing JSON crashes recovery.
7. `compact()` missing or resets high-water.

## Local validation hints

```bash
# from a TB3 checkout with this task under tasks/
for check in checks/check-*.sh; do bash "$check" tasks/lease-queue-fencing; done
harbor run -p tasks/lease-queue-fencing --agent oracle --env docker
harbor run -p tasks/lease-queue-fencing --agent nop --env docker
```
