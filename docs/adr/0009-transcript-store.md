# 0009. Transcript store

- Status: Accepted
- Date: 2026-11-27

## Context

Job 3.1 builds transcripts, job 3.6 adds transcript import, and [ADR 0008](0008-storage-shape.md)
left the transcript store to this ADR, so the boundary between it and domain storage has to be
fixed first. The constraints:

- **The roadmap's Client/server contract decision.** Streams carry small whole entities,
  transcript items among them, and the server sends one-line summaries of subagents.
- **Database.** SQLite only.
- **The Control-plane spec decision.** No state outside the DB, and an in-process node boundary
  that keeps multi-machine nodes possible later.
- **A9 in the threat model.** Transcripts are job data, including secrets that leak into them.

Outpost's transcript handling is requirements, not a template:

- `src/runtime/claude/transcripts.ts` reads Claude's own JSONL under `~/.claude/projects` and
  re-parses it on every read. The runtime's file is the only copy, and Outpost's history of a
  session ends when Claude's cleanup deletes it.
- `src/runtime/jsonl-transcripts.ts` keeps Outpost's own JSONL for other runtimes. Its
  `readItems` loads a whole file and skips a torn tail line.
- Session files run to several MB, which is why `transcript-scan.ts` reads them in chunks.
- A cockpit paint with 60 subagents was 1.1 MB, half of it collapsed subagent tiles.
- The control-plane spec (`docs/superpowers/specs/2026-11-05-control-plane-design.md`, §2.5 and
  §3.4) keeps a bounded `session_output` window in the database and the full log on the node,
  with a per-session `seq` and re-sends that are idempotent by it. The seq and the idempotency
  are worth keeping. The two tiers served remote nodes, which v1 doesn't have.

This ADR doesn't decide item kinds or tables (job 3.1), import (job 3.6), stream cursors on the
wire (the subscription ADR), caps, page sizes and periods (the performance budgets and the
retention policy), or what is redacted (the retention and redaction policy).

## Decision

### Where transcripts live

- Transcripts live in a SQLite file of their own, the **transcript store**, in the server's data
  directory beside the domain database. It has the domain database's file permissions and is
  outside every action's file scope (I14). Its path is job 2.1's.
- **It isn't domain storage.** It holds no domain table, so
  [ADR 0007](0007-command-event-outbox.md)'s one writer and its command rules govern the domain
  database, not this file.
- This ADR reads ADR 0007's "the DB", "state change" and "second writer" as the domain database.
  Transcript items aren't state in ADR 0007's sense, and the transcript store is a separate file
  with its own writer.
- **One transcript writer** makes every write to it: appends, imports, redactions and deletions.
  They run one at a time on its own queue, in short transactions, separate from the command
  queue. Schema migrations are the migrations policy's, as in ADR 0007, and restore is job
  2.1's. No session or runtime opens the file; how backup copies it is job 2.1's.
- Its tables follow ADR 0008's shape: `STRICT` tables, columns and JSON as ADR 0008 divides them,
  keyset list queries, versioned JSON, and no table loaded whole. Redaction, below, is the one
  exception.
- The migrations policy and job 2.1's backup and restore cover both files.

### Transcripts and items

- **A transcript is one ordered log of items.** Its ID is a TypeID with prefix `trn`
  ([ADR 0006](0006-ids.md)). Each agent session has one main transcript, and each subagent has
  its own, which records its parent transcript and the item that started it. A session's record
  holds its `transcriptId`.
- **An item is a whole, completed entry**, such as a message, a tool call, a tool result or a
  shell run. Job 3.1 defines the kinds and bodies. A tool result is its own item, naming its
  call. Text still streaming isn't stored; the subscription ADR decides whether clients see it
  live.
- Each item has:
  - `seq`: per transcript, from 1, assigned by the writer in append order, and never reused for
    a seq the domain database cites.
  - `itemKey`: from the runtime's own item ID, unique per transcript. Appending a key the
    transcript already has is a no-op, which absorbs adapter retries, backfill overlap and a
    later remote node's re-sends. Job 3.1 defines how `itemKey` is derived where a runtime has
    no item ID, or a call and its result share one.
  - `at`, `kind`, and a JSON body with its schema version `v` beside it, as an event has.
- The performance budgets cap an item's size. A larger output is truncated at write, with a
  marker.
- **Items aren't rewritten after commit, except by redaction.** Retention deletes a whole
  transcript or its lowest-seq prefix, so every remaining `(transcriptId, seq)` the domain
  database cites names the item it always named.
- **Backup and restore treat the two files as a pair** (job 2.1). If the store still comes back
  older than the domain database, a recovery walks the domain database in capped keyset pages, as
  a maintenance sweep under ADR 0008. Job 3.1 designs it, including how the highest cited seq is
  found. Before the store serves reads, the writer:
  - re-applies every transcript deletion and redaction the domain database records;
  - resumes each transcript above the highest seq the domain database cites for it, and records
    that resume floor, so no cited seq names a new item.

### References from domain records

- **A reference is a `transcriptId` and a seq or seq range.** Both are columns, as ADR 0008
  makes references and seqs, including a gate's range bounds and a derived fact's seq.
- A gate's conversation ([ADR 0004](0004-gate-state-machine.md)) is a range of its author's
  transcript, from the seq where the gate opened to the seq where it settled, which the settled
  gate records. Decide never reads the store, so both bounds are seqs the domain database
  already holds at that moment, such as a seq the author's turn-end command carries. Job 4.4
  designs them.
- Resuming a session, including a cold resume into a new runtime session while ADR 0004's
  author is `resuming`, appends to the same transcript.
- **Transcript first.** An item commits to the store before any command cites its seq. A crash
  in between leaves items nothing cites, which is harmless.
- **References tolerate missing items.** A read whose items are gone returns `expired`, not an
  error, and clients show it. That covers retention deleting a transcript or a prefix, and a
  read at or below a resume floor where no item exists. A cursor past both the resume floor and
  the last item waits for more.

### What crosses the boundary

- **From the store to domain records, only references and derived facts.** A derived fact is a
  bounded value, such as a subagent's one-line summary, a step's activity lines (up to four, per
  the [interaction model](../design/1.4-interaction-model.md)), a title, item counts or the last
  activity time, recorded with the seq it's current to. A summary is one line of plain text,
  capped by the API conventions ADR. The session's adapter derives these from the live item
  stream and records them through `server` commands, coalesced at a rate the performance budgets
  bound. A fact whose seq is at or below the one already recorded is a no-op, which deduplicates
  these commands as ADR 0007 requires of `server` commands. Whether they emit events is job
  3.1's. No domain row is filled by reading the store.
- **Decide never reads the store.** A command that needs something from a transcript carries it
  in its payload. Restart recovery, ADR 0007's `server.started`, reads only the domain database.
- **No event body is copied from the store.** An event may cite a reference.
- **Content that enters through a command is domain data in its own right**, even when the same
  text also appears in a transcript:
  - artifacts and their revisions, and write and reply drafts
  - what a session submits, such as its move and memo
  - an outbox row's approved payload (I2)
  - approvals and pins, with the exact call each decided (I2, I11)
  - comments and tickets from sources
  - input dc sends a session, such as a message or an answer to an ask, until the session
    receives it. Job 3.6 designs that row and clears its body once the transcript holds the
    delivered item.
- **Decisions about a session are domain records**: approvals, mode changes including
  [ADR 0005](0005-session-permission-modes.md)'s refused `SetMode`, and gate decisions. The
  server merges them into the session view it sends, so clients don't.
- **Every list read of the store is a keyset page** (ADR 0008), whether a client opening a
  session or a subagent, the improver, export or a retention sweep. Item lists key on
  `(transcriptId, seq)`, and nothing reads a whole transcript into memory. A step's view shows
  its subagents' summaries from domain rows, not their transcripts.

### Runtime-owned transcript files

- **A runtime's own transcript files are never authoritative**, such as the Claude Agent SDK's
  JSONL under `~/.claude/projects` or Codex's session history. The store takes items from the
  runtime's live event stream, across the node interface, not by reading those files, apart from
  the cases below. The runtime keeps its file as its own resume state, and Majula doesn't edit it
  in v1.
- Majula reads a runtime's file only in these cases (the runtime also reads it to resume):
  1. **Import.** dc imports a session started outside Majula, by a device command. The writer
     copies it once, in bounded chunks, parsing it as untrusted data (I16). From then on the
     store's copy is authoritative, and later changes to the file aren't followed. Job 3.6
     designs how the copy runs after the import command commits.
  2. **Crash backfill.** On resuming a session after a server crash, the adapter may append
     items the runtime's file has and the store missed. `itemKey` drops the overlap. Job 3.1
     decides whether to do it.
- The retention and redaction policy decides whether Majula ever deletes or rewrites runtime
  files. A session's record keeps the runtime's session ID, which locates the file.
- **An adapter's debug logs aren't transcripts.** If job 3.1 keeps native runtime frames for
  debugging, as Outpost's `event-ndjson.ts` does, they are logs under job 2.4's secret
  redaction, with short retention, and no domain record or client reads them.

### Retention and redaction hooks

The retention and redaction policy decides what goes and when. This ADR fixes how:

- **Deleting or redacting transcript data is a domain decision first.** A command, from a
  retention sweep or from dc, commits the decision and enqueues an outbox row of a checked kind,
  `transcript.delete` or `transcript.redact`. The transcript writer applies it after commit and
  the effect's result settles the row, so it is idempotent and resumes after a restart under
  ADR 0007's outbox rules.
- **Redaction replaces an item's body** with a marker carrying the reason and time, and keeps
  its seq, kind and `itemKey`. For the transcript store only, this is the one exception to
  ADR 0008's rule that JSON never rewritten after commit stays as written.
- **Retention deletes** whole transcripts or a lowest-seq prefix, in keyset pages.
- **Domain copies are outside these hooks.** Event bodies, which ADR 0007 never edits, and
  artifacts, outbox payloads, approvals and pins, which are JSON that ADR 0008 never rewrites,
  may hold the same text as a transcript. If the policy redacts any of them, it supersedes or
  amends ADR 0007 or ADR 0008 for that case and weighs I2. Derived facts, such as summaries,
  activity lines and titles, can also hold item text. They are rewritable domain JSON, so the
  policy can clear them without amending an ADR.

## Alternatives

- **The same file, each item a command.** Every item would get a receipt and an event and wait
  behind commands on ADR 0007's single queue, and the events table would grow with all output.
  Items aren't decisions, so they need neither receipts nor decide.
- **The same file, written by a second connection outside the bus.** SQLite allows one writer
  per file, so appends would contend with command transactions. Transcripts would dominate the
  file, so the backup before each migration, restore and `VACUUM` would scale with them. ADR
  0007's rule that nothing writes a domain table outside a command would need an exemption.
- **Append-only JSONL per transcript, as Outpost's `jsonl-transcripts.ts` keeps.** There's no
  index for a keyset page, so a page read scans the file, and Outpost's reader loads it whole.
  Torn tail lines are skipped, and redaction rewrites files.
- **The runtime's own files as authoritative, as Outpost reads Claude's.** The format is per
  runtime and changes without notice, the files live outside the server's data directory, the
  runtime's cleanup deletes them, every read re-parses them, and Majula can't retain or redact
  them. Some runtimes keep no usable history.
- **A bounded window in the domain database and the full log on the node**, as the control-plane
  spec's §2.5 and §3.4 propose. The two tiers serve remote nodes, which v1 doesn't have. Since
  no domain record is filled from the store, a later multi-machine design can move the store
  behind the node interface without changing domain records.

## Consequences

- Job 2.1 offers its storage primitives for the second file, declares the `trn` prefix, and
  backs up and restores the two files as a pair.
- Job 3.1 designs the item tables and kinds, `itemKey` derivation, truncation, the transcript
  writer and its recovery after an older-store restore (re-applying deletions and redactions,
  and the resume floor), the adapter's derived-fact commands, and whether to backfill after a
  crash. The writer's next seq comes from a persisted per-transcript high-water mark, not from
  the remaining items, so a prefix deletion can't restart numbering.
- Job 4.4 designs where a gate's conversation bounds come from.
- Job 3.6 designs import, transcript streaming and the row that holds input until delivery.
- Job 3.14 reads a subagent's transcript only when dc opens it, in pages. Job 4.10's improver
  reads transcripts by reference, in pages.
- The subscription ADR defines the transcript stream, which resumes from `(transcriptId, seq)`.
  It fans out after the transcript writer commits and isn't ADR 0007's domain change feed. It
  resyncs clients after a restore, since their cursors live outside the domain database.
- The node interface ADR carries items with their `transcriptId` and `itemKey`.
- The API conventions ADR caps summary length. The performance budgets cap item size, page size
  and the derived-fact rate.
- The retention and redaction policy builds on the hooks above, and decides runtime files and
  domain copies. It keeps a record of each transcript deletion and redaction for as long as a
  store backup might predate it, since restore recovery re-applies them.
- ADR 0008's clause on a second database engine isn't triggered: the store is a second SQLite
  file, not a second engine.
- Filling domain records by reading the store, decide reading it, runtime files becoming
  authoritative, or rewriting items other than by redaction needs an ADR that supersedes this
  one.

## Security

This touches T1 × B1, T2 × B1, T2 × B2 and T2 × B4.

- **I8, I10 (T1 × B1):** a client reads transcripts only through authenticated device calls, and
  revocation ends the transcript stream as it does any stream.
- **I16 (T2 × B1):** items are untrusted content and render as inert text. Import parses a
  runtime's file as data.
- **I13 (T2 × B2):** items arrive through the runtime adapter, not a session callback, and
  derived facts are `server` commands, so a session can't append to another session's transcript
  or set a derived fact on another record. Derived facts come from agent-controlled content and
  render as inert text (I16).
- **I14 (T2 × B4):** the transcript store is outside every action's file scope, and no session
  holds a handle to it. A secret that leaks into an item is A9's case, and redaction is its
  hook.
- **I7:** adapter debug logs fall under job 2.4's secret redaction.
- A runtime's own files are a copy of A9 outside Majula's control in v1. A session's reach to
  them is bounded by I3's declared scope.

R1 and R2 stand. The threat model changes with this ADR: its §1 and B4 name the transcript store
beside the domain database.
