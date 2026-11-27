# 0007. Commands, events, outbox

- Status: Accepted
- Date: 2026-11-26

## Context

Every later job changes server state, and job 2.2 builds the command bus, so the contract every
state change follows has to be fixed before jobs 2.1 and 2.2 design tables. The constraints:

- **The roadmap's Control-plane spec decision** adopts no state outside the DB and idempotent
  external writes (the spec's §7 audit), and drops leases and fencing for v1. Job 2.2 is done when
  killing the process at every step of a commit shows no divergence and no duplicate external
  write.
- **Roadmap 1.8:** structured external writes (open or merge a PR, post a review or reply, source
  writebacks) run from the server's outbox through its own clients, with no agent session involved.
- **[ADR 0004](0004-gate-state-machine.md):** gate transitions become commands. An approval binds
  to one revision, and to a head or comment for a write, and is consumed when the write runs.
- **[ADR 0006](0006-ids.md)** leaves command IDs and the actor's place in the command envelope to
  this ADR.
- **The roadmap's anti-goal** forbids dropping a controller-loop invariant from the control-plane
  spec's §10 (items i–xii) without deciding to.

Outpost's control-plane spec (`docs/superpowers/specs/2026-11-05-control-plane-design.md`, §§2.1–2.4
and §7) and its `src/db/backend.ts` (`CommitBatch`, `CommitResult`) are the requirements source,
not a template.

## Decision

- **Commands with authoritative state rows.** State rows are the truth. Events are the retained
  timeline, written in the same transaction. Effects leave only through outbox rows committed with
  the state that caused them.
- **One writer and one SQLite transaction per command**, with nothing done outside it until it
  commits.
- **A `device` command's ID is its idempotency key.** A retry with the same ID gets the stored
  receipt. `session` and `server` commands deduplicate as Commands describes.
- **External writes are at least once, and each one is idempotent**: an already-done check where
  the target allows a read-back, at most once where it doesn't.

### One writer, one transaction

- Every state change goes through the command bus. Nothing writes a domain table outside a
  command transaction; schema migrations are the migrations policy's.
- Commands run one at a time on one in-process queue, each in one SQLite write transaction
  (`BEGIN IMMEDIATE`). It commits the receipt, the state rows, the events, any change-feed rows the
  subscription ADR defines, the outbox rows, and timer inserts and deletes, or none of them.
- **Decide is pure and synchronous.** It reads the rows it needs inside the transaction and
  computes the writes, with no I/O and no `await` while the transaction is open. The clock and ID
  minting are injected, so job 2.2's fault harness can drive it deterministically.
- **Commit before act.** No external call, stream fan-out, session start or message, or
  state-changing tool-call gate decision, such as consuming a pin, happens until the transaction
  commits. Fan-out to subscribers and waking effect workers follow the commit.
- **No state outside the DB.** In-memory state is a cache rebuilt from committed rows and is never
  authoritative. Anything that must happen later is a timer row, never a `setTimeout`. Restart
  recovery reads only the DB.
- **No writer lease, epoch or fencing.** One process owns the file, as the roadmap decided, and no
  envelope carries an epoch.

### Commands

| Field             | Meaning                                                                                                                             |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `commandId`       | TypeID with prefix `cmd`. A client mints it and reuses it on retry; the server mints it for `session` and `server` actors           |
| `kind`            | The command type, defined by the job that adds it                                                                                   |
| `actor`           | `device` with its `deviceId`, `session` with its session ID, or `server`. Set from the authenticated caller, never from the payload |
| `expectedVersion` | Optional. The `version` of the target entity the client acted on                                                                    |
| `payload`         | The command's body                                                                                                                  |

- A command whose ID already has a receipt doesn't run again, and the stored receipt is returned.
  The receipt keeps a digest of the kind and payload, and a reused ID with a different digest is
  refused, not answered with the old result.
- A `session` command's receipt also records its session ID and the runtime's tool-call ID, and a
  retried call with the same pair gets that receipt rather than running again. On a runtime that
  loses the tool-call ID across a cold resume, a retried submit is refused as a second move for
  the turn, and the session reads the committed move from its envelope. Every other session command
  kind that isn't idempotent carries a revision or `expectedVersion`, so a retry that would repeat
  a committed change is refused as `stale`.
- `server` commands are deduplicated by the state they consume. A timer fire deletes its timer row
  and an effect result settles its outbox row, so a second delivery is a no-op.
- `server` covers timers, effect results and standing policies. An approval under a pre-approval
  also cites the pre-approval's record, which names the device that set it.
- A stale `expectedVersion` is rejected as `stale`, with the current version.
- **Each command kind declares the actor kinds that may issue it, and decide checks it.**
  - A `session` never grants a pre-approval, changes a mode, approves or abandons a gate, or
    changes permissions. It acts only within its role: a step's session on its own step and, as
    an author, its own gate; a planner on its own job, where a replan supersedes that job's gates
    as ADR 0004 says; a manual session on itself.
  - A `device` issues dc's decisions: granting a pre-approval, choosing a mode, approving or
    abandoning a gate and changing permissions.
  - Among gate and mode transitions, a `server` command issues only those ADRs 0004 and 0005 give
    the Server, such as approval under a pre-approval, lease expiry, the return to Action and
    Bypass ending on restart or revocation.
- Domain revisions, such as a gate's `revision` in ADR 0004, stay in the payload. They aren't the
  entity's `version`: an author answering a question changes the gate but not its revision, and
  Approve must still succeed afterwards.

### Receipts

- Every command that commits gets a receipt: `commandId`, `kind`, `actor`, `receivedAt`, the
  payload digest, `status` (`accepted` or `rejected`), a typed rejection code (`stale`,
  `forbidden`, `invalid`, `conflict` when the target's state no longer allows the transition, or a
  domain code), `result` and the seq range of its events.
- A reused ID with a different digest, and a command that can't commit, return an error with no
  receipt.
- A rejected command commits its receipt, and may commit events that record the refusal, as ADR
  0005 keeps a refused `SetMode` in the session's record. It commits no state change, outbox row or
  timer. A client that acts on a rejection sends its next attempt under a new command ID.
- The receipt is the unary RPC's response, returned after commit. `accepted` means the intent and
  its consequences are committed, not that an effect ran; the client sees that in the entity's state
  on its subscription.
- A failed authentication, or a command from a revoked device, is refused before the bus and gets
  no receipt. Presence on the device, which approving and entering Bypass need, is verified there
  too, by job 1.7's mechanism.
- Receipts outlive any client's retry window. The retention policy sets how long.

### Events

| Field       | Meaning                                                                                                         |
| ----------- | --------------------------------------------------------------------------------------------------------------- |
| `seq`       | The event's identity. Allocated in the transaction, gapless at allocation and in commit order across the server |
| `commandId` | The command that caused it                                                                                      |
| `actor`     | Copied from the command                                                                                         |
| `at`        | Commit time, from the injected clock                                                                            |
| `entity`    | The kind of entity the event is about, such as a job, step, gate or session                                     |
| `entityId`  | That entity's TypeID                                                                                            |
| `jobId`     | The job the entity belongs to, when it belongs to one                                                           |
| `kind`      | The event type                                                                                                  |
| `v`         | The body's schema version                                                                                       |
| `body`      | JSON                                                                                                            |

- One command's events take a contiguous seq range, and each entity's events follow the global
  order.
- **Events are never rewritten.** A changed shape is a new `v`, and readers keep reading the older
  ones. The retention policy may delete events with their job, decides when events about entities
  outside a job go, and never edits one.
- Events aren't replayed to rebuild state. They are the job history, the audit trail and the
  improver's input.
- Whether subscribers read events or a separate change feed is the subscription ADR's. Whatever
  they read commits in the same transaction as the change it describes.

### Outbox and effects

- An outbox row carries `kind`, a unique `idempotencyKey`, `payload` (everything the effect
  needs), `cause` (the `commandId` that enqueued it), `state` (`pending`, `claimed`, `done`,
  `failed`, `unknown` or `cancelled`), `attempts`, `notBefore` and `result`. Enqueuing a key twice
  is a no-op. `cancelled` is terminal: the row will never run.
- **Delivery is at least once.** After commit, an effect worker claims rows through a `server`
  command and runs each effect outside any transaction. It reports the outcome as a `server`
  command keyed by the row, which settles the row and applies its consequences in one transaction.
- **Multi-step effects resume.** An effect records an intermediate result, such as a squash commit
  sha, on its outbox row through a `server` command before taking the next step, so a retry
  resumes from it rather than starting over. Recording the same result again is a no-op.
- **Each effect kind is one of two classes:**
  - **Checked**, where the target allows a read-back. The effect runs an already-done check first
    and adopts what it finds, such as a pushed sha, an open PR for the branch or a comment carrying
    its marker, rather than repeating it. A transient failure is retried with backoff through
    `notBefore`, up to a per-kind limit, then `failed`.
  - **At most once**, where no read-back exists, such as a webhook post. The claim commits before
    the send. A crash after the claim settles as `unknown`, which is never retried automatically
    and is shown to dc.
- **Restart.** At boot, one `server.started` command moves claimed checked rows back to `pending`,
  so their already-done check runs, and claimed at-most-once rows to `unknown`. The same command
  carries the rest of restart recovery: steps, dispatches and controllers, including invariant xii;
  ADR 0004's restart transitions for open gates; and ADR 0005's end of Bypass.
- **Results are data.** External content in a result reaches control flow only through typed fields
  that decide reads.
- **Probes** are effects whose result feeds a decision: merge readiness, rerun readiness,
  draft-file digests and reads of upstream state. They keep decide free of I/O. A probe changes
  nothing outside, so a duplicate is harmless.
- **Timers** are rows committed with the command that arms them. A server loop turns due rows into
  `timer.fired` commands, and the command that consumes a timer deletes it. Soaks, delivery quiet
  windows, schedule triggers and dc's edit-lock lease are timers. A controller never arms its own
  wake; a plan step's soak is plan data the server turns into a timer when the step parks.
- **Credentials.** An effect runs with the server's own GitHub or source client. No payload or
  result carries a credential.

### Structured external writes

- Opening or merging a PR, posting a review or reply, and source writebacks are outbox effects. No
  agent session is involved.
- The command that runs an approved write, whether after dc's `ApproveGate` or a pre-approval at
  `drafted`, enqueues an outbox row with exactly the approved payload and its bound preconditions:
  the PR's head and base shas, or the comment's ID and state. The row's idempotency key derives
  from the gate and the approved revision, so one approval enqueues at most one write.
- Each write kind also has a domain key, such as project, head branch and `pr-create`, that its
  already-done check reads and that carries across redrafts. Both keys and the check are designed
  per kind from the control-plane spec's §7.1 table. Opening a PR adopts an existing PR for the
  head branch.
- Immediately before the send, the effect re-validates its row and gate through a `server`
  command, and doesn't send unless the row is still claimed and the gate still `approved`. A
  refusing re-validation moves the row to `cancelled` in the same transaction.
- The gate stays `approved` while the row is in flight, and the effect's result moves it on:
  - `ok`: the gate becomes `consumed`.
  - A failed precondition, where the bound head, base or comment moved and the effect refused to
    write: the row becomes `cancelled` and the gate `superseded`. As ADR 0004 says, a redraft
    then opens a new gate, or a comment-walk position settles when its comment is gone or
    resolved.
  - `failed`, for a checked write: the gate stays `approved` and shows the outcome. dc can retry,
    which re-runs the same row under the same key, behind its already-done check.
  - `unknown` or `failed`, for an at-most-once write: nothing re-sends it. dc can redraft, which
    supersedes the gate and opens a new one whose card says the write may already have run;
    approving it enqueues a new row under the new revision's key.
- A head or base move that matches the in-flight row's own claimed or recorded result, such as its
  own push or squash-merge, doesn't invalidate its gate.
- When ADR 0004 supersedes an `approved` gate before its write runs, the same transaction moves a
  pending or `failed` row to `cancelled`, and a claimed row's re-validation stops it. A supersede
  that commits between the re-validation and the send can't recall the write; the write's result
  is recorded against the superseded gate and shown to dc.
- Writes an agent makes mid-turn under exact-match pins aren't outbox effects; jobs 1.8 and 3.4
  own them. A pin is consumed by a command that commits before the tool-call gate returns allow,
  so a restart can't spend it twice.

### Controller-loop invariants

The roadmap forbids dropping any of the control-plane spec's §10 invariants without deciding to.
Under this contract:

| #    | Invariant                                                                              | Under this contract                                                                                                                                                                                                                      |
| ---- | -------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| i    | One `NextMove` per turn                                                                | Preserved. A controller's move is a `session` command; decide refuses a second move for the turn, and a retried submit with the same tool-call ID gets the first receipt                                                                 |
| ii   | No round cap; only the policy guards                                                   | Preserved. The contract adds no cap, and the guards are decide-time checks over committed state                                                                                                                                          |
| iii  | A `wait` with `resumeAt` is refused; only the watcher and redelivery wake a controller | Preserved. A controller never arms its own wake, and wakes are commands from the watcher's probe results and inbox delivery                                                                                                              |
| iv   | `changedSignals` suppressions, and the quiet window measured from the oldest held item | Preserved. Inbox items are rows with their arrival time, the quiet window is a delivery timer at oldest plus quiet, and suppressions are decide logic; head-moved during the server's own push or PR open reads that effect's outbox row |
| v    | A writable `resolve` means merged, with its carve-outs                                 | Preserved. PR facts arrive as observation commands, so decide checks `resolve` against committed state                                                                                                                                   |
| vi   | `duplicatePrCreate`                                                                    | Preserved. Opening a PR is a checked effect whose already-done check adopts an existing PR for the head branch                                                                                                                           |
| vii  | Only a user route grants a pre-approval                                                | Preserved. Pre-approval commands are `device` only; planners write proposed pre-approvals                                                                                                                                                |
| viii | The tool-call gate fails closed                                                        | Preserved. A command that can't commit returns an error with no receipt, a decision that needs a commit it can't make denies, and an `unknown` effect is never retried automatically                                                     |
| ix   | Pins match exact text and digests, are consumed at allow and released only on failure  | Preserved. Consumption commits before allow, release is a command issued only on a failed call, and a restart releases nothing                                                                                                           |
| x    | Action-bound calls never fall back to global or project scope                          | Unaffected. Grant resolution is the permission engine's (1.8, 3.2), and this contract routes no tool decision                                                                                                                            |
| xi   | `isOpeningPr` is cleared on restart                                                    | Replaced. The in-memory flag becomes the PR-open outbox row, which persists, returns to `pending` on restart and adopts a PR opened before the crash                                                                                     |
| xii  | A running dispatch fails on restart; a waiting controller resumes, not respawns        | Preserved. Boot recovery is one `server.started` command that reads only the DB and does both in one transaction, alongside the outbox recovery                                                                                          |

Replacing xi is this ADR's recorded decision. Its aim holds, nothing stuck opening and no
duplicate PR, without the flag.

## Alternatives

- **Plain CRUD plus a change log.** Handlers write rows and append a change record. There are no
  receipts, so a retry repeats the command, and effects are called inline or from ad-hoc queues, so
  a crash between the commit and the call loses or repeats a write. That breaks I15 and job 2.2's
  done criterion.
- **Event sourcing.** Events are the truth and state is a fold over them. Every read needs a
  projection anyway, every shape change needs upcasters and a rebuild, and the fault harness gets
  harder. With the state rows existing either way, making them authoritative costs nothing and
  removes the rebuild path.
- **A separate durable queue for effects**, such as a second SQLite file or an in-process job
  queue. Writing state and effect to two stores needs two-phase commit or reconciliation. One file
  and one transaction is simpler, and is what makes no divergence checkable.
- **Outpost's design as it stands.** Its lease and epoch fencing served a laptop-to-cloud failover
  v1 doesn't have. Its 202-then-watch acknowledgement is unnecessary when a local SQLite commit
  can answer the call directly. Its receipts, single transaction, keyed outbox, already-done checks
  and timer rows are kept on merit.

## Consequences

- Job 2.1's storage layer offers one write-transaction primitive with no `await` inside, and fault
  points at each step of a commit.
- Jobs 2.1 and 2.2 give every entity a command can target a `version`.
- Job 2.2 designs the receipt, event, outbox and timer tables, the bus, the effect worker, the
  outbox and timer part of `server.started`, and the fault harness, which kills the process at
  every commit and effect step. It names the record prefixes beyond `cmd`, and keys the first
  structured write kinds and designs their already-done checks.
- Job 4.2 designs the step and dispatch part of `server.started` and binds write drafts to the
  outbox. Job 4.4 designs its controller and gate parts and tests every row of the invariants
  table. Job 3.4 designs its mode part.
- The subscription ADR decides what subscribers read.
- Jobs 1.8 and 4.2 key the write kinds they add.
- The retention policy sets how long receipts and events are kept.
- Job 4.4's spec carries xi's replacement forward, as the roadmap asks of a changed invariant.
- A second writer, a writer lease or epoch, authoritative events, an effect that runs before its
  cause commits, or any change to the invariants table needs an ADR that supersedes this one.

## Security

This touches T1 × B1, T1 × B2, T2 × B1, T2 × B2, T2 × B3, T2 × B4, T2 × B5, T3 × B1 and T3 × B5.

- **I15:** every outbox write has a unique idempotency key and is checked or at most once. Only a
  checked write is retried, behind its already-done check; an `unknown` or `failed` at-most-once
  write runs again only as a new approval of a redraft. A restart never repeats a write.
- **I2:** the outbox payload is exactly the approved call, one approval enqueues at most one write,
  and the bound preconditions and the gate are re-checked just before writing. A supersede that
  races the send is recorded against its gate and shown to dc, never hidden.
- **I11:** every command records its actor, set from the authenticated caller. A replayed command
  gets its receipt and changes nothing. A gate decision, or any command carrying a revision or
  `expectedVersion`, replayed under a new ID meets a decided gate or a stale version and is refused.
- **I8, I9:** `device` commands arrive only over the authenticated, encrypted client channel, which
  keeps commands from being replayed off the wire. `session` commands arrive over the
  session-authenticated local channel (I13), and `server` commands arise inside the process.
  Webhook intake is signature-checked before it becomes an observation command. Effects verify
  TLS to every service.
- **I6, T2.14:** no `session` command grants a pre-approval, changes a mode, approves or abandons a
  gate or changes permissions, and among gate and mode transitions a `server` command issues only
  those ADRs 0004 and 0005 give the Server.
- **I5, I11 (T1 × B2):** entering Bypass and approving are `device` commands that record the
  device, with presence verified before the bus, and the server ends Bypass on restart or
  revocation.
- **I3, I4:** unchanged; this contract routes no tool decision.
- **I13:** a `session` command acts only on its own step. A planner runs as its job's planning
  step, whose scope is that job, and a manual session has no step and acts only on itself.
- **I14:** sessions reach state only through commands, never the database.
- **I1:** a command that fails or can't commit denies.
- **I10:** a revoked device's commands are refused before the bus.
- **I7:** effects use the server's own credentials, and no payload or result carries one.
- **I16:** effect and probe results are data.

R1 and R2 stand. The threat model is unchanged: B5 and I15 already describe outbox writes.
