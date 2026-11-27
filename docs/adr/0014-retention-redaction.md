# 0014. Retention and redaction

- Status: Accepted
- Date: 2026-11-27

## Context

Earlier ADRs left how long data is kept, and what is redacted, to this policy:

- **[ADR 0007](0007-command-event-outbox.md):** how long receipts are kept, which must outlive any
  client's retry window, and when events about entities outside a job go. Events may be deleted
  with their job and are never edited.
- **[ADR 0008](0008-storage-shape.md):** retention deletes in keyset pages.
- **[ADR 0009](0009-transcript-store.md):** what is redacted, whether Majula ever deletes or
  rewrites runtime files, whether domain copies of transcript text are redacted, and keeping a
  record of each transcript deletion and redaction for as long as a store backup might predate it.
  It fixed the hooks: `transcript.delete` and `transcript.redact` outbox rows, redaction replacing
  an item's body with a marker, and retention deleting whole transcripts or a lowest-seq prefix.
- **[ADR 0010](0010-subscriptions-cursors.md):** the change feed's window.
- **The threat model.** A9 is job and transcript data, including secrets that leak into
  transcripts. I7 says a credential is never logged, never stored in plaintext and never sent to a
  client.

Outpost keeps its runtime event logs for 14 days (`docs/design/repo-layout.md`), and a session's
history lasts as long as the runtime's own transcript file. It doesn't redact transcripts.

This ADR doesn't decide tables, commands or settings screens (jobs 2.1, 2.2, 3.1, 4.2 and 6.5),
how long clients cache data they don't reopen (jobs 3.8 and 3.9, under ADR 0010), or what an
approval card shows of a call that holds a secret (job 1.8).

## Decision

- **Every record belongs to a retention unit:** a job, a manual session or the server.
- **A unit's domain records are kept until dc deletes the unit,** and its transcripts for 90 days
  after it ends, by default.
- **Credentials are masked in transcript items before Majula stores them.**
- **dc redacts transcript items after commit** through ADR 0009's hook.
- **Redaction doesn't reach domain copies, runtime files or backups.** Deleting the unit removes
  the domain copies.

### Retention units

- A **job** owns its steps, dispatches, gates and their artifact revisions, drafts, approvals and
  pins, outbox rows, timers, derived facts and sessions, the events whose `jobId` it is, and those
  sessions' transcripts.
- A **manual session**, one that belongs to no job, is a unit of its own, with its transcripts,
  derived facts, events and the decisions about it, such as
  [ADR 0005](0005-session-permission-modes.md)'s refused `SetMode`.
- The **server** owns the rest: devices, projects, settings, permissions, action definitions and
  their events.
- The `transcript.delete` rows a unit's deletion enqueues belong to the server.
- A unit is **terminal** when its job is done, failed or abandoned, or its manual session has
  ended.
- A design doc that adds a table names the unit its records belong to. The spec template asks for
  it.

### What's kept

| Data                                                                                                                         | Kept                                                                                                                                                      | Removed by                                               |
| ---------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| A unit's domain records: steps, gates and artifact revisions, drafts, approvals and pins, outbox rows, events, derived facts | Until dc deletes the unit. Setting _job history_: forever by default, or N days after the unit is terminal                                                | dc's command, or the sweep when the setting is on        |
| A unit's transcripts                                                                                                         | 90 days after the unit is terminal. Setting _transcript history_: 30, 90 or 365 days, or forever                                                          | The sweep, through `transcript.delete` (ADR 0009)        |
| Receipts                                                                                                                     | 30 days after `receivedAt`, whatever their unit                                                                                                           | The sweep                                                |
| Change-feed rows                                                                                                             | 24 hours, the window ADR 0010 asks for                                                                                                                    | ADR 0010's pruning timer                                 |
| The server's records and their events                                                                                        | Forever                                                                                                                                                   | The job that owns the record, such as removing a project |
| Transcript deletion and redaction records                                                                                    | Forever in v1. They hold IDs, seqs, reason, time and actor, never content                                                                                 | Nothing                                                  |
| Server logs and adapter debug logs                                                                                           | 14 days                                                                                                                                                   | `host/`, by file age                                     |
| Backups Majula makes, including pre-migration pairs ([ADR 0013](0013-db-migrations.md))                                      | At most 30 days, and at most the three most recent pre-migration pairs. The pair taken before a migration that isn't yet applied is kept until it applies | `storage/`                                               |

- dc changes _job history_ and _transcript history_ by `device` command.
- Deleting a unit deletes its transcripts too, even before the transcript period ends.
- Timers are deleted by the command that consumes them (ADR 0007), not by retention.

### How removal runs

- Domain data is removed by commands, as ADR 0007 requires. dc's deletions are `device` commands.
  The sweep is a `server` command under dc's settings as a standing policy, run from a timer row,
  one keyset page per command (ADR 0008).
- Deleting a unit's records writes ADR 0010's `removed` change rows, and enqueues
  `transcript.delete` for its transcripts.
- A unit's records are deleted only once the unit is terminal. The deleting command checks that
  the unit is still terminal and has no `pending` or `claimed` outbox row, not counting the
  `transcript.delete` rows the deletion enqueued, and otherwise refuses with `conflict`. Receipts
  and change-feed rows go by age alone.
- A reference into a deleted transcript reads as `expired` (ADR 0009), including after a unit is
  reopened.
- No `session` command deletes or redacts anything, or changes a retention setting.

### Receipts and the retry window

- Receipts are kept 30 days. Clients drop a command that has no receipt after 7 days, so no retry
  outlives its receipt (ADR 0007). Jobs 3.8 and 3.9 build that.

### Masking at intake

- When the core's consumer of `item` events ([ADR 0012](0012-node-interface.md)) receives an item,
  it masks credentials in the body before the transcript writer stores it or any derived fact is
  taken from it. This is a change at write, like ADR 0009's truncation, not a redaction after
  commit, so clients and derived facts see only masked text.
- Items that enter the store another way, through import or crash backfill (ADR 0009), pass
  through the same redactor before the transcript writer stores them.
- It matches:
  - the exact values of credentials the server holds in clear: GitHub and source tokens, MCP
    tokens, the server's own keys, values from its secret providers, and device session tokens and
    pairing codes while it holds them in clear (A3, A5, A6 and A7). Values shorter than 8
    characters aren't matched. Hashed codes and device keys are matched by pattern or not at all;
  - known token patterns, such as provider API keys, GitHub tokens, private-key blocks and bearer
    headers.
- One redactor serves this and job 2.4's log redaction. A match becomes a marker naming its kind,
  never the value.
- A runtime's own login (A2) is a credential Majula never holds (`docs/policy/agent-terms.md`), so
  it is matched only by pattern. Masking is best-effort for anything not matched by value.

### Redaction after commit

- dc redacts transcript items by `device` command, which enqueues ADR 0009's `transcript.redact`.
- The same command clears the derived facts recorded from that transcript at or above the earliest
  redacted seq, such as summaries, activity lines and titles, and shows a placeholder until the
  next fact. Derived facts are rewritable JSON (ADR 0009).
- The transcript writer bumps the transcript's `generation`, which resets open streams and purges
  client caches of the redacted text (ADR 0010).
- v1 doesn't rescan stored items when a new credential becomes known.

### Domain copies, runtime files and backups

- **Domain copies keep their text.** Event bodies, artifacts, drafts, outbox payloads, approvals
  and pins aren't redacted, so ADRs 0007 and 0008 stand and an approved write still sends exactly
  what was approved. dc removes a secret from them by deleting the unit.
- **Runtime files.** Majula doesn't delete or rewrite a runtime's own transcript files in v1. They
  follow the runtime's retention, and neither masking nor redaction reaches them.
- **Backups** hold data as of when they were taken. Restoring a pair undoes deletions and
  redactions made after it, so restore (job 2.1) warns dc and advises rotating any credential
  redacted since. Apart from a pair kept for a migration that isn't yet applied, no backup
  outlives 30 days, so a deletion reaches every other backup Majula keeps within 30 days.

### Absolutes and their exceptions

| Rule                                                                   | Exceptions                                                                                                                          |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| Domain data is removed only by commands                                | None. Logs and backups aren't domain data: `host/` and `storage/` remove them by age                                                |
| A unit's records are deleted only once the unit is terminal            | Receipts and change-feed rows, which go by age whatever their unit. Timers, which the command that consumes them deletes (ADR 0007) |
| No backup Majula makes outlives 30 days                                | Copies dc makes by hand, outside Majula. The pair taken before a migration that isn't yet applied (ADR 0013)                        |
| A transcript item is masked before Majula stores it or derives from it | None. Masking is best-effort for credentials Majula doesn't hold                                                                    |
| Redaction doesn't change domain copies                                 | Derived facts, which are rewritable and are cleared                                                                                 |
| Majula doesn't delete or rewrite a runtime's own files in v1           | None                                                                                                                                |
| Events are never edited                                                | None. They leave only with their unit (ADR 0007)                                                                                    |

## Alternatives

- **Keep everything forever.** Transcripts dominate the disk, and leaked secrets stay readable.
- **A short default for job history.** dc and the improver lose history they use, while a finished
  job's domain rows are small.
- **Redacting domain copies.** It amends ADRs 0007 and 0008, and an approved payload would no
  longer be the bytes dc saw (I2).
- **Masking only after commit.** The secret reaches clients and derived facts first.
- **Rescanning history when a credential becomes known.** A walk over every stored item for each
  new secret.
- **Deleting runtime files.** It breaks the runtime's own resume, and acts on files Majula doesn't
  own.

## Consequences

- Job 2.1 caps backup age and count, and warns on restore.
- Job 2.2 runs the receipt sweep. Job 2.3 prunes the change feed at 24 hours.
- Job 2.4 builds the shared redactor and deletes logs by age.
- Job 3.1 masks items at intake, applies `transcript.delete` and `transcript.redact`, and keeps the
  deletion and redaction records.
- Jobs 3.8 and 3.9 drop commands with no receipt after 7 days.
- Jobs 4.2 and 6.5 build unit deletion and the two retention settings.
- Job 7.4's docs say runtime files and backups hold copies Majula doesn't redact.
- The spec template asks which unit a new table's records belong to.
- Redacting domain copies, deleting runtime files, or removing deletion and redaction records while
  a backup might predate them needs an ADR that supersedes this one.

## Security

This touches T1 × B1, T2 × B1, T2 × B2 and T2 × B4.

- **I8, I10 (T1 × B1):** a shorter transcript history bounds what a stolen phone can read, and
  deletions and redactions reset client caches (ADR 0010).
- **I16 (T2 × B1):** masking markers render as inert text.
- **I7:** masking keeps credentials Majula holds out of stored and streamed items.
- **I6, I13 (T2 × B2):** no `session` command deletes, redacts or changes a retention setting.
- **I14 (T2 × B4):** backups and logs are outside every action's file scope.
- **I11:** deletions, redactions and retention settings are `device` commands that record the
  device, and the sweep acts under dc's setting.
- **I2:** redaction never changes an approved payload.
- **Residual:**
  - credentials Majula doesn't hold are masked only when they match a pattern;
  - domain copies keep a secret until their unit is deleted;
  - runtime files and backups hold copies that redaction doesn't reach;
  - restoring a backup brings back text redacted after it.

R1 and R2 stand. The threat model is unchanged.
