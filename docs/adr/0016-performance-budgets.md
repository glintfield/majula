# 0016. Performance budgets

- Status: Accepted
- Date: 2026-11-27

## Context

Earlier ADRs left their caps and numbers to the performance budgets:

- **[ADR 0008](0008-storage-shape.md):** nothing loads a growing table at boot or in the server's
  loops, and job 2.1's contract suite checks that boot reads don't grow with a seeded history.
- **[ADR 0009](0009-transcript-store.md):** an item's size cap, the page size and the rate of
  derived-fact commands.
- **[ADR 0010](0010-subscriptions-cursors.md):** the page, batch and snapshot caps, and the
  control-plane spec's per-paint target of under 100 KB on a 60-subagent fixture. Its heartbeat
  defaults to 30 s.
- **[ADR 0011](0011-api-conventions.md):** the default and maximum page size.
- **[ADR 0012](0012-node-interface.md):** each request kind's default deadline and result size cap.

Outpost is the reason these are numbers rather than intentions. A cockpit paint with 60 subagents
was 1.1 MB, half of it collapsed subagent tiles, and froze the client (ADR 0009's Context). Its job
store read every job file at boot.

This ADR doesn't decide client rendering budgets, which jobs 3.7, 3.8 and 3.9 set, or how a
benchmark is built.

## Decision

- **Budgets are measured on two fixtures,** so a number means the same thing in every job.
- **Byte and row-count budgets are deterministic tests. Time budgets are CI benchmarks** that fail
  at twice the budget, to absorb runner noise.
- **Oversized transcript items are truncated with a marker.** What an approval shows is refused
  instead.
- **A later design doc may tighten a budget.** Loosening or removing one needs an ADR that
  supersedes this one.

### Fixtures

Jobs 2.1 and 2.5 build them:

- **Large history:** 10,000 terminal jobs, 1,000,000 events and 1,000,000 transcript items.
- **Active:** 50 active jobs, one of them with 60 subagents, and artifacts of up to 16 KB.

No cap limits active work. The budgets are measured at the active fixture's 50 jobs, and
[ADR 0017](0017-concurrency-limits.md) bounds what runs at once.

### Budgets

| Budget                                                        | Number                                                                                                         | Check                                       |
| ------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- | ------------------------------------------- |
| Boot to serving, with no pending migrations, on both fixtures | ≤ 2 s                                                                                                          | CI benchmark                                |
| Rows boot reads                                               | The same as an empty history with the same active work                                                         | Deterministic, in ADR 0008's contract suite |
| A keyset list page at maximum size, server-side               | p95 ≤ 50 ms                                                                                                    | CI benchmark                                |
| A point read                                                  | p95 ≤ 5 ms                                                                                                     | CI benchmark                                |
| A command's transaction, decide and commit                    | p95 ≤ 10 ms and p99 ≤ 50 ms, since every command shares one queue                                              | CI benchmark                                |
| The cockpit's snapshot                                        | ≤ 100 KB                                                                                                       | Deterministic bytes                         |
| Every job scope's snapshot, including the 60-subagent job     | ≤ 100 KB, not counting open gates' artifact bodies                                                             | Deterministic bytes                         |
| One entity message                                            | ≤ 256 KB. A write that would exceed it is refused                                                              | Enforced at write                           |
| An artifact's text                                            | ≤ 128 KB. A larger one is refused with `invalid`, never truncated                                              | Enforced at write                           |
| A snapshot or batch page on a stream                          | ≤ 200 entities and ≤ 512 KB                                                                                    | Enforced                                    |
| A unary list page                                             | Default 50 and maximum 200 items, and ≤ 512 KB                                                                 | Enforced                                    |
| A transcript item's body                                      | ≤ 64 KB. A larger one is truncated at write, keeping its head and tail, with a marker giving the original size | Enforced at write                           |
| A transcript page                                             | Default 50 and maximum 200 items, and ≤ 512 KB                                                                 | Enforced                                    |
| Derived-fact commands                                         | ≤ 1 per session per second, coalesced to the latest. A status change is sent at once                           | Enforced                                    |
| A node request's result                                       | ≤ 1 MB. Larger content is read in ranges or pages                                                              | Enforced                                    |

- Page sizes are ADR 0011's `page_size` default and cap. A page ends at whichever of its limits it
  reaches first.
- The heartbeat stays ADR 0010's 30 s default.

### Node deadlines

ADR 0012's default deadline for each kind of request:

| Requests                                                | Default deadline |
| ------------------------------------------------------- | ---------------- |
| Local reads: files, diffs and local git                 | 10 s             |
| `session.send`, `session.interrupt` and `session.close` | 10 s             |
| One chunk of a transcript import                        | 30 s             |
| `session.start`                                         | 60 s             |
| Git network operations, and creating a checkout         | 120 s            |

`decideToolCall`'s deadline is job 1.8's, since a tool call may wait on dc.

### Off the boot path

- Nothing between process start and serving waits on an external service or starts a runtime.
  Runtime detection, usage reads and the PR watcher's polls start after the server is serving.

### Changing a budget

- The design doc of the job that owns a number may tighten it. Loosening a budget or removing one
  needs an ADR that supersedes this one.

### Absolutes and their exceptions

| Rule                                                                                       | Exceptions                                                                                                    |
| ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------- |
| Boot to serving is ≤ 2 s on the fixtures                                                   | Pending migrations and their backup ([ADR 0013](0013-db-migrations.md)), during which calls get `unavailable` |
| Nothing on the boot path waits on the network or starts a runtime                          | None                                                                                                          |
| On the active fixture, the cockpit's snapshot and every job scope's snapshot stay ≤ 100 KB | Open gates' artifact bodies, each ≤ 128 KB                                                                    |
| Oversized transcript items are truncated with a marker                                     | None. Artifacts and anything else an approval shows are refused instead, and node results are read in ranges  |
| Every node request has a default deadline                                                  | `decideToolCall`, which is job 1.8's, and a session's lifetime, which isn't a request (ADR 0012)              |

## Alternatives

- **No numbers, left to each job.** ADRs 0009 to 0012 would have nothing to cite, and each job
  would set its own limits against nothing.
- **Time budgets only.** Timing on CI runners is noisy. Bytes and rows read are exact, so they gate
  hard and the timings gate at twice the budget.
- **Outpost's frames, which carried a whole job.** That is the 1.1 MB paint.
- **Truncating artifacts like transcript items.** An approval would show less than the write sends
  (I2).

## Consequences

- Jobs 2.1 and 2.5 build the fixtures. Job 2.1 counts boot reads and checks query plans.
- Job 2.2 benchmarks command transactions.
- Jobs 2.3 and 3.6 enforce the snapshot, page and byte caps, with deterministic tests.
- Job 3.1 truncates items, coalesces derived facts, and applies the node deadlines and the result
  cap.
- Job 4.2 refuses artifacts over the cap.
- Loosening or removing a budget needs an ADR that supersedes this one.

## Security

This touches T2 × B1.

- **I2 (T2 × B1):** what an approval shows is refused when too large, never truncated.
- **I16 (T2 × B1):** truncation markers render as inert text.
- **I1:** `decideToolCall`'s deadline is job 1.8's, and ADR 0012 already denies on its timeout.

Denial of service, beyond failing closed, is out of scope (threat model §8). R1 and R2 stand. The
threat model is unchanged.
