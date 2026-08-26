# Task Design: `lease-queue-fencing` (updated)

**TB3 baseline:** `45e819259a95fb10e43dcebcc11b73140ace3b32`  
**Category:** Software / Systems  
**Expert time:** ~8 hours  

## Concept

Repair a durable visibility-lease work queue used by settlement workers so fencing tokens, idempotent receipts, crash/torn-write recovery, and concurrent queue instances on one durable root all satisfy `/app/CONTRACT.md`.

## Why difficulty was increased

A single-file happy-path rewrite against an over-prescriptive contract is too easy for frontier models. This revision:

- requires **multi-instance** coherence on one durable root (stale private memory is a fail);
- requires **torn trailing durable record** tolerance without losing earlier state;
- softens the contract toward **semantic outcomes** (monotonic fences, durability) rather than prescribing journal record schemas;
- expands behavioral coverage so incomplete fencing/durability fixes fail.

## Realistic incident

Rolling restart during settlement: workers race, leases expire, a crash truncates the last durable write, and a second queue instance on the same root must not accept a stale fence.

## Difficulty assessment (pre-frontier)

| Model target | Assessment |
| ------------ | ---------- |
| GPT-5.6 Sol xhigh | Still a **risk** it may solve; strengthened but not guaranteed to yield 0/3 |
| Claude Opus 5 max | Same — **risk** |

Frontier evidence is required before claiming defeat. Do not assume failure.

## Verifier strategy

Split behavioral modules; fresh roots only; unprivileged pytest; binary reward; CTRF; read-only hashes.

## Anti-cheat

Separate verifier; no goldens in agent image; negative probes (no-change, fence-skip) score 0; official `/cheat` still required.
