# 0017. Concurrency limits

- Status: Accepted
- Date: 2026-11-27

## Context

Job 4.2 builds the launch governor with its concurrency limits, the capability inventory lists the
governor among Outpost's work capabilities, and earlier ADRs left limits here:

- **[ADR 0007](0007-command-event-outbox.md):** no state outside the DB, anything later is a timer
  row, and invariant xii: on restart a running dispatch fails and a waiting controller resumes.
- **[ADR 0011](0011-api-conventions.md):** `resource_exhausted`, with `RetryAfter`, when a rate or
  concurrency limit refuses a call.
- **[ADR 0012](0012-node-interface.md):** the concurrency policy limits how many node requests run.
- **Agent terms** (`docs/policy/agent-terms.md`, Q4). Usage comes only from data the runtimes emit:
  Claude's last-seen SDK values and Codex's `account/rateLimits/read`. Cursor has no usage source.
  Plan limits assume ordinary, individual use, which argues for a modest default.

Outpost's `src/work/launch-governor.ts` is requirements, not a template:

- Three priorities. `user`, an explicit click, always fires. `immediate`, a high-priority job or a
  reactive round such as a CI fix, skips the budget and the slot cap but not a pause. `queued`
  waits on all three.
- A pause, a budget gate from usage headroom, and slots that taper from the configured maximum
  toward one as usage rises. An "ignore the budget for an hour" override.
- It drains `immediate` first, then jobs already in progress, then oldest first.
- `src/storage/preferences-store.ts` defaults the maximum to 5.
- The parked queue, the active set and the override live in memory, which ADR 0007 rules out.

This ADR doesn't decide the governor's tables and commands, which launches count as reactive, or
the taper's curve (job 4.2), or pairing redemption's rate limit (job 1.7).

## Decision

- **A turn the server runs needs a free global slot and a free slot for its runtime.**
- **Outpost's three priorities, pause and budget gate stay, and its queue moves into the DB.**
- **Idle runtime processes are closed above a cap,** and cold-resumed when needed.
- **The server's own work has fixed pools,** and a full command queue refuses only `device`
  commands.

### Launch slots

- A **slot** is one agent turn the server runs, held from launch until the turn ends.
- The **global maximum** is 5 by default. dc sets it from 1 to 16 by `device` command.
- Each runtime has a **runtime maximum**, which defaults to the global one and which dc may lower.
- Step rounds, controllers, dispatched children and scheduled runs all take slots.

### Priorities

- **`user`** is dc's explicit action, such as messaging a session, starting a manual session or
  launching a job. It starts at once, past the pause, the budget and the slots, and counts toward
  the slots it occupies.
- **`immediate`** covers the launches job 4.2 classifies as reactive, and every launch of a job dc
  marked high priority. It skips the budget and the slot caps, not a pause.
- **`queued`** waits for the pause to lift, the budget gate to open and a slot to free.
- Parked launches start in this order: `immediate`, then launches for jobs already in progress,
  then oldest first.

### The queue is domain state

- A parked launch is a row, with its priority and enqueue order.
- The pause, the global and runtime maximums and high priority are settings dc changes by `device`
  command. "Ignore the budget for an hour" is a timer row.
- Which slots are occupied is a cache rebuilt from committed session state, never authoritative.
- On restart, parked launches stay parked, and running turns follow invariant xii.
- No `session` command changes a priority, the pause or a limit.

### Budget gate and taper

- The budget gate and the taper apply per runtime, and only to a runtime with a usage source the
  agent terms allow. A runtime without one, such as Cursor or an ACP agent, has slots but no budget
  gate.
- As a runtime's usage rises, its slots taper toward one. Job 4.2 sets the curve, and job 4.9's
  schedules read the same usage.

### Live runtime processes

- At most 20 runtime processes stay alive by default, and never fewer than the global maximum.
- Above the cap, the server closes the process of the idle session that was least recently active.
  The session is cold-resumed when it is next needed.
- The server doesn't close a session mid-turn, or one in Bypass, since Bypass ends on a cold resume
  ([ADR 0005](0005-session-permission-modes.md)).

### Server-side limits

| Work                  | Limit                                                                                                                                                   |
| --------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Effects and probes    | ≤ 4 in flight per external service, such as GitHub or one job source                                                                                    |
| Node requests         | ≤ 4 concurrent git network operations, and ≤ 16 other git and file requests                                                                             |
| The transcript writer | One queue ([ADR 0009](0009-transcript-store.md))                                                                                                        |
| The command bus       | One queue (ADR 0007). At 1,000 pending commands, new `device` commands get `resource_exhausted` with `RetryAfter`. `session` and `server` commands wait |
| RPC, per device       | ≤ 64 open streams and ≤ 32 unary calls in flight. Beyond either, `resource_exhausted` with `RetryAfter`, checked after authentication                   |

### Changing a limit

- The global and runtime maximums, the pause and high priority are dc's settings.
- The other numbers here are starting values. The design doc of the job that owns one may change
  it, with a measurement.

### Absolutes and their exceptions

| Rule                                                               | Exceptions                                                                                  |
| ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------- |
| A turn starts only with a free global slot and a free runtime slot | `user` and `immediate` launches                                                             |
| Nothing starts while paused                                        | `user` launches                                                                             |
| The governor keeps no state outside the DB                         | Slot occupancy, a cache rebuilt from committed rows                                         |
| Live runtime processes stay under the cap                          | Sessions mid-turn or in Bypass aren't closed, so the cap can be exceeded until they're idle |
| Only `device` commands are refused when the command queue is full  | None                                                                                        |
| Only dc changes a limit, the pause or a priority                   | None                                                                                        |

## Alternatives

- **Outpost's in-memory queue.** A restart loses every parked launch and the override, against
  ADR 0007.
- **One global limit only.** One runtime's account limit would hold back launches on the others.
- **No cap on live processes.** Idle sessions would hold memory for as long as their jobs wait.
- **Refusing `session` and `server` commands when the queue is full.** An effect's result could be
  dropped, leaving its outbox row unsettled (I15).

## Consequences

- Job 4.2 builds the governor: the queue rows, the settings, the taper and which launches are
  reactive.
- Job 4.9's schedules launch as `queued`.
- Job 2.2 builds the effect and probe pools and the command queue's limit.
- Job 3.1 builds the node request pools and the live-process cap.
- Jobs 2.3 and 2.6 enforce the per-device RPC limits.
- Jobs 4.14 and 6.5 show the queue and its settings.
- Keeping governor state outside the DB, letting a session set a priority, or using a usage source
  the agent terms don't allow needs an ADR that supersedes this one.

## Security

This touches T1 × B1 and T2 × B2.

- **I8 (T1 × B1):** per-device limits apply after authentication, so they add no unauthenticated
  surface.
- **I3, I6 (T2 × B2):** no session raises a priority or a limit, and a scheduled launch runs with
  its policy's grants, whatever its slot.
- **I5:** the process cap never closes a session in Bypass.
- **I15:** a full command queue never refuses an effect's result.

Denial of service, beyond failing closed, is out of scope (threat model §8). R1 and R2 stand. The
threat model is unchanged.
