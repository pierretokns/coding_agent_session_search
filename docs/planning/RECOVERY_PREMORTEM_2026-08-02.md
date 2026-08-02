# CASS recovery pre-mortem — 2026-08-02

## Decision

The interrupted recovery is not safe to restart with the current implementation
and launch procedure. The live archive and raw mirror remain preserved, but the
28 GB candidate at
`doctor/candidates/1785694772964-doctor-reconstruct-candidate` is only an
`in_progress` artifact: it has no completion receipt, no coverage report, and
no durable reconstruction checkpoint. It must not be promoted.

The recovery gate is therefore: make reconstruction resumable and durably
supervised, then prove candidate coverage, promotion safety, lexical readiness,
semantic readiness, real hybrid execution, and watcher stability.

## Observed run signal

The durable run
`doctor-recovery-20260802-171320-7436` demonstrated an important monitoring
rule. While parsing a large Codex payload, the progress-record count held at
17,197 for roughly two minutes, but the process stayed CPU-bound, the candidate
SQLite WAL and receipt stream continued to grow, and the next checkpoint later
advanced to 17,342 and then 17,430. A flat record count is therefore not, by
itself, a stall. The low-noise watch must sample process ownership/CPU together
with progress bytes, receipt/WAL growth, and free space; intervene only when
all activity signals are flat for the configured timeout or the supervisor
exits.

## Failure modes and controls

| Failure mode | Evidence / likelihood | Impact | Detection gate | Control |
|---|---|---:|---|---|
| Foreground process is killed with the terminal/session | The previous run ended with an empty JSON result, a vanished process, and an `in_progress` manifest. High | Hours of work appear lost; no trustworthy outcome | Durable run log, heartbeat, exit envelope, process owner | Run through a persistent one-shot supervisor with stdin detached and durable stdout/stderr; never rely on a PTY lifetime |
| Candidate has no resumable checkpoint | Existing candidate contains only DB/WAL/SHM and manifest; `artifact_count=0`, coverage schema `0`. Certain | Restart repeats a full scan and may fill the disk again | Kill/resume fixture; checkpoint mtime and processed-manifest count | Append-only, fsynced manifest ledger with source fingerprint; reopen the same candidate only when the fingerprint matches |
| DB commit succeeds before evidence/progress commit | Current reconstruction inserts before staging evidence and has no transaction-spanning checkpoint | Resume can duplicate work or leave unverifiable candidate evidence | Crash-window test between insert and evidence stage | Make evidence staging idempotent; record a manifest only after DB and evidence are both durable; replay duplicates safely |
| Raw mirror changes during recovery | Continuous ingestion can add or mutate source manifests | Candidate may represent a mixed corpus and coverage comparison becomes ambiguous | Source fingerprint mismatch at resume and before promotion | Snapshot a deterministic verified-manifest fingerprint; restart into a new candidate when it changes |
| Hard-link fallback becomes a physical copy | Hard links are same-filesystem only; fallback exists for portability | Candidate can consume another ~36 GB and exhaust free space | Receipt reports fallback kind; free-space check before copy | Track physical-copy bytes, enforce a storage-pressure floor, and fail closed before unsafe staging |
| WAL/SHM or DB growth consumes the remaining disk | Candidate grew to ~28 GB while the raw-mirror evidence directory stayed small | Host-wide failure or corrupted partial artifact | Periodic filesystem free-space probe and candidate byte telemetry | Abort before the configured floor; preserve candidate and emit a structured failure context |
| Stale/interrupted candidates are mistaken for current candidates | Multiple old candidates exist and interrupted state is intentionally retained | Wrong candidate can be promoted or selected | Dry-run candidate selection with source fingerprint and live inventory | Select only completed, current, coverage-approved candidates; resumable selection requires matching fingerprint |
| Promotion races with watcher/indexing | Watcher is intentionally paused during recovery | Lock contention, stale live inventory, or unsafe swap | Lock/owner probe plus pre/post live-inventory equality | Keep watcher disabled through promotion and derived-index rebuild; start it only after post-repair probes pass |
| Hybrid search silently degrades to lexical | README explicitly documents lexical fallback when the model is absent | Search appears healthy but lacks semantic recall | `models status`, `models verify`, HNSW build, and real `--mode hybrid --robot-meta` result | Treat fallback metadata as a failed semantic gate, not a successful hybrid run |
| Quarantine is treated as harmless cleanup | CASS retains quarantined generations by policy; user requested full corpus | Missing sessions or hidden stale state survives “healthy” status | Quarantine inventory and source/archive coverage comparison | Inspect every quarantine class; remove only through fingerprinted, reversible cleanup after coverage is proven |
| CM is run before CASS is healthy | Earlier CM run reported unavailable/degraded CASS and wrote an empty playbook | Findings are incomplete and misleading | CASS health/status plus real search before CM | Rerun CM only after archive, lexical, semantic, hybrid, and watcher gates pass |

## Required red-green-refactor proof

1. **Red:** a unit/integration test demonstrates that an interrupted candidate
   can be resumed without creating a second candidate and that already durable
   manifests are skipped.
2. **Green:** the resume ledger is source-fingerprinted, append-only, fsynced at
   bounded batch intervals, and evidence staging is idempotent.
3. **Refactor:** the durable launch wrapper and operator runbook use the same
   checkpoint/heartbeat contract; tests cover source drift, hard-link fallback,
   and the DB/evidence crash window.

## Promotion and search acceptance gates

- Candidate manifest: `lifecycle_status=completed` and
  `coverage_gate.promote_allowed=true`.
- Repair dry-run fingerprint matches the apply command exactly.
- Promotion receipt, rollback reference, and post-repair probes exist.
- Live DB opens and archive coverage does not decrease.
- Lexical index rebuild reaches a verified current state.
- Semantic model is installed and verified; semantic/HNSW assets are built.
- A real hybrid query reports hybrid execution, not lexical fallback.
- Watcher is restarted only after recovery and remains alive across a detached
  operator session.
- CM is rerun against the verified live corpus and its output is retained.
