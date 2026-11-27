# 0010. Subscriptions and cursors

- Status: Accepted
- Date: 2026-11-27

## Context

Job 2.3 builds the subscription primitive, and earlier ADRs left parts of it here.
[ADR 0007](0007-command-event-outbox.md) left whether subscribers read events or a separate change
feed, [ADR 0008](0008-storage-shape.md) the stream cursor, and
[ADR 0009](0009-transcript-store.md) the transcript stream, whether clients see text still
streaming, and how clients resync after a restore. The constraints:

- **The roadmap's Client/server contract decision.** Streams carry small whole entities, such as a
  job summary, step, gate, draft or transcript item, not field-level patches. Clients render
  presentation-ready data and never re-derive state.
- **Multiple servers per client.** An app keeps one profile per server, every profile stays
  connected, and profiles share nothing.
- **[ADR 0003](0003-api-schema.md).** Unary and server-streaming calls only, and the Android client
  turns off connect-kotlin's 10 s stream deadline.
- **I10.** Revocation takes effect on open streams.

The [API spike](../spikes/1.6-api-spike.md) ran `Watch`, a server stream over one buffered log.
`after_seq` replays buffered events and continues live. It returns `failed_precondition` when the
gap has left the buffer and `out_of_range` when `after_seq` is ahead. Both apps cancel the stream
when backgrounded and resume it with `after_seq`, with no gaps or duplicates. The server checks the
token only when a call starts, so revoking it doesn't end an open `Watch`.

Outpost's control-plane spec (`docs/superpowers/specs/2026-11-05-control-plane-design.md`, §2.2,
§2.5, §4 and Phase 2) is requirements, not a template. Its client protocol is one socket with
topics (`cockpit`, `job:<id>`, `session:<id>`, subagent topics and `approvals`). A `changes` feed
stores each delta's document or field patch, and a cursor below the feed's low-water mark gets a
snapshot. Phase 2's exit criteria are no frame carrying a whole job, no paint above 100 KB on a
60-subagent fixture, and an e2e test of resume inside and below the window.

This ADR doesn't decide proto messages or the list of scopes (job 2.3 and the jobs that add
entities), credentials (job 1.7), the feed's window and the caps (the retention policy and the
performance budgets), error codes beyond the Connect codes named here (the API conventions ADR) or
how clients store their cache (jobs 3.8 and 3.9).

## Decision

- **Snapshot, then deltas of small whole entities**, on one server stream per scope.
- **A change feed separate from events**, committed with the state it describes, read from a
  cursor `(epoch, changeSeq)`.
- **A well-formed cursor that can't resume gets a fresh snapshot in the stream**, not an error.
- **Each batch of deltas is a consistent cut:** the scope exactly as committed at its cursor.
- **Revoking a device ends its open streams.**

### Two stream families

- **Domain subscriptions** carry entities whose state is in the domain database, such as job
  summaries, steps, gates, item views, the attention set, comment walks, sessions and drafts. They
  read the change feed below.
- **Transcript streams** carry one transcript's items from the transcript store (ADR 0009). They
  don't read the change feed, and they fan out after the transcript writer commits.

### The change feed

- A **change row** records that one streamed entity changed. Its columns are `changeSeq`, the
  entity kind, the entity ID, the `commandId` that caused it, and the scope keys subscriptions
  filter on, such as `jobId`. It holds no entity data.
- **`changeSeq`** is allocated once per committing command that writes change rows, in that
  command's transaction, gapless and in commit order across the server. The command's change rows
  share it, and `(changeSeq, kind, entityId)` is unique. The counter persists across restarts, and
  positions are compared only within one epoch. A rejected command commits no state change
  (ADR 0007), so it writes change rows only for what a streamed entity shows of what it does
  commit, such as the refused `SetMode` that ADR 0005 keeps in a session's record.
- Change rows commit in the same transaction as the state they describe, as ADR 0007 requires of
  whatever subscribers read.
- An entity that is deleted or leaves a scope gets a change row that streams send as `removed`,
  with its kind and ID. Leaving a scope with time, such as a job aging out of Recently cleared, is
  a timer row whose `server` command changes state, such as the job's cockpit membership, and its
  change row is derived like any other. The job that defines the scope designs it.
- Change rows are derived from the rows and events a command writes and from declared view
  dependencies, such as an item view's dependence on its step, gates and session. Commands don't
  list them by hand.
- **The feed is a window, not history.** A `server` command run from a timer row prunes it in
  keyset pages, dropping rows at or below the floor, which `server.started` raises to the head, and
  rows older than the window the retention policy sets. Events remain the history.
- **The window's floor** is a persisted low-water mark. Pruning advances it, `server.started` sets
  it to the head, and it never passes the head.

### Cursors

- A **domain cursor** is `(epoch, changeSeq)`, two fields on the wire. It says the client holds
  every change in its scope through `changeSeq`. Clients may compare positions within one epoch.
- **The epoch** is a random value that every `server.started` command (ADR 0007) mints and records.
  A restart, a restore, a database file copied in by hand or an upgrade each start a new epoch. It
  isn't a record ID ([ADR 0006](0006-ids.md)), any more than the server's identity is, and it
  isn't the writer epoch ADR 0007 rules out: it fences nothing, and only names a run of the feed.
- **A receipt also carries the feed position at its commit**, with its epoch. A client's stream
  reflects the command once its cursor reaches that position. On a position from an earlier epoch,
  such as one in a receipt returned again after a restart, the client stops waiting, because the
  current epoch's snapshot is authoritative. A position from a newer epoch than the client's
  stream is pending until the stream resets into that epoch.
- A client keeps cursors per server profile and per scope, in that profile's own cache, and never
  sends one profile's cursor to another server. Epochs are random per server, so a cursor links
  nothing.
- A cursor crosses B1, so the server parses it strictly, as it parses every scope ID, and refuses
  a malformed one with `invalid_argument`.

### Subscribe: snapshot, then deltas

- **One server stream per scope:** `Subscribe(scope, cursor)`, with the cursor optional. ADR 0003
  rules out bidi, so a client changes what it watches by opening and closing streams, which HTTP/2
  multiplexes on one connection.
- **A scope is a bounded live set**, sized by active work, not by history. Examples are the cockpit
  (job summaries of active and recently cleared work, and the attention set) and one job (the job
  and all its steps, gates, item views, comment walk and session summaries). Reading every step of
  one job is a keyset read on the parent's ID, which ADR 0008 allows. Finished history isn't a
  scope; clients read it through unary list calls with page tokens.
- **What scopes carry.** The cockpit carries summary fields only, never a job's steps or gates. A
  subagent appears in a job or session scope only as its summary (ADR 0009's derived facts), and a
  client opens its transcript stream only while dc has it open. A job, each of its steps and each
  gate are separate entities, so a change to one step sends that step, not the job. There is no
  separate approvals scope: the cockpit's attention set holds an entry for every item blocked on
  dc, across jobs. The jobs that build other surfaces, such as schedules and settings, define their
  scopes.
- **Snapshot.** With no cursor, or one that can't resume, the server reads the scope's entities and
  the feed's head `H` in one read transaction. It sends them in pages, the first marked `reset` and
  only the last carrying `(epoch, H)`. The client replaces what it held for the scope when the last
  page arrives.
- **Deltas.** From cursor `c`, a batch covers `(c, H']`. The server reads the scope's change rows in
  that range, and the current entities they name, in one read transaction. It sends each entity
  once, whole or as `removed`, with `(epoch, H')`. A large batch goes in pages with the cursor on
  the last, and the client applies a batch only once it is complete.
- **No read transaction is held across sends.** The server reads a snapshot or batch whole, closes
  the transaction, then sends its pages. The performance budgets cap snapshot and batch size, and
  a scope whose snapshot exceeds the cap is a design error their tests catch.
- **Entities are rendered on read** from committed rows and events as presentation-ready messages,
  so a stream that falls behind skips intermediate states and catches up in one batch. Nothing is
  buffered per commit.
- **Heartbeat.** An idle stream gets `(epoch, head)` every 30 s by default, from a read that finds
  no change rows for its scope in `(c, head]`, so it is an empty batch. It keeps NAT and proxies
  from closing the stream, and moves a quiet scope's cursor so it stays inside the feed's window.
- **Gates.** A gate is sent whole, with its `lastEdit` hunks, as the
  [interaction model](../design/1.4-interaction-model.md) asks. Batches can skip revisions, so a
  client animates an edit only when the gate's revision is one past the one it holds, and otherwise
  replaces the gate.

### Resume, retention and bad cursors

| Cursor                                             | The server sends                      |
| -------------------------------------------------- | ------------------------------------- |
| Current epoch, from the window's floor to the head | Deltas from the cursor                |
| Current epoch, below the window's floor            | A reset snapshot                      |
| Current epoch, ahead of the head                   | A reset snapshot, and logs a warning  |
| An earlier epoch                                   | A reset snapshot                      |
| None                                               | A snapshot                            |
| Any, for a scope whose root is gone                | A reset to an empty scope             |
| Malformed                                          | `invalid_argument`, ending the stream |

- A scope whose root is gone, such as a job retention deleted, resets to an empty scope that
  sends `removed` for the root.
- These resets replace the spike's `failed_precondition` and `out_of_range`. Every case has the
  same recovery, so an error would add a round trip and a second path in each client. Only a
  malformed cursor is an error.
- `invalid_argument`, `unauthenticated` and `permission_denied` are Connect's standard codes.
- A client reconnects with its last complete cursor after backgrounding, a network drop or a
  server restart, backing off from 250 ms to 5 s, as the spike's Swift client does. On
  `unauthenticated` it first refreshes its credential through job 1.7's mechanism and reconnects;
  if the refresh fails, as it does for a revoked device, it stops and shows the profile's state.
  On `permission_denied` or `invalid_argument` it stops that subscription only.
- Clients turn off the stream deadline (ADR 0003).

### Ordering

- Within one stream, batches arrive in `changeSeq` order. A client that applies only complete
  batches never shows part of a command, such as a step that moved on beside a gate still open.
- Across streams there's no order. Two scopes can show one entity at different cuts for a moment,
  and their cursors say which is newer.
- A receipt is returned after its commit (ADR 0007), so it can arrive before or after the stream
  shows the change. Its feed position settles which.

### Transcript streams

- **`SubscribeTranscript(transcriptId, cursor)`**, with the cursor optional. A transcript cursor
  is `(epoch, generation, seq)`, with `seq` per transcript as ADR 0009 assigns it.
- With no cursor, the server sends the transcript's last page, whose final message carries the
  starting `(epoch, generation, seq)`, then items as they commit. Older items come from unary
  keyset pages read backwards.
- With a cursor, the server replays the items after `seq` in keyset pages, then goes live. Items
  are whole and keyed by `(transcriptId, seq)`, so a resend is harmless.
- A cursor whose next items retention has deleted gets ADR 0009's `expired`, then the items from
  the first that remains. Within the current epoch and generation, a cursor past both the resume
  floor and the last item waits for more, as ADR 0009 says; within one epoch, only a client bug
  produces one.
- A cursor from an earlier epoch or another generation gets a reset: the last page again, marked
  `reset`. This is how clients resync after a restore.
- **Redaction reaches clients.** `generation` is a per-transcript counter in the transcript store.
  The transcript writer bumps it in the store transaction of the last page when it applies a
  redaction, or a deletion dc orders, so no reset happens before every page is applied. It then
  sends each open stream on that transcript a reset carrying the new generation. A client that
  wasn't streaming gets the reset when it reconnects with its older generation. Retention deletes
  don't bump it; their cursors get `expired` as above.
- Idle transcript streams get the same heartbeat as domain subscriptions, carrying their cursor.
- **No text still streaming.** Clients see an item once it commits whole. Partial text would be a
  field-level patch, and would fan out before the writer commits. A session's activity lines,
  which are derived facts (ADR 0009), show that it's working.

### Revocation and credentials

- Every stream is bound to the credential that opened it and the device it names, and the server
  keeps a registry of open streams by `deviceId`.
- **The command that revokes a device ends that device's streams** with `unauthenticated`, after
  it commits. A stream may read a batch between that commit and the close, so the read transaction
  of each snapshot, batch and heartbeat also reads the device's revocation, and a stream whose
  device is revoked in that cut sends nothing more. Transcript items fan out from the transcript
  writer, outside the domain commit order, so the server checks the device's revocation before
  sending each one. A batch or item already sent isn't recalled.
- A stream also ends with `unauthenticated` when its credential expires, after which the client
  refreshes its credential and reconnects with its cursor. It ends with `permission_denied` when a
  change job 1.7 defines, such as narrowing a device's scope, means the call that opened it would
  now be refused.

### Client cache

- A profile's cache holds what its subscriptions deliver, with each scope's cursor. History read
  through unary pages is shown but not kept across a reset or an app relaunch. Cached data for a
  scope or transcript the client doesn't reopen is dropped after a bound jobs 3.8 and 3.9 set.
  `removed` entries and resets purge deleted and redacted data from whatever is reopened before
  then.

### Connection state

- This ADR reads ADR 0007's rules of no state outside the DB and timer rows for later work as
  covering domain state and later domain work, as ADR 0009 read its terms. The stream registry,
  heartbeats and credential-expiry deadlines are connection state, which is neither. They decide
  nothing and end with the process, after which clients reconnect with their cursors. Pruning the
  feed changes domain state, so it runs from a timer row.

## Alternatives

- **ADR 0007's event `seq` as the cursor.** Derived facts (ADR 0009) are `server` commands that
  may emit no event, yet must reach clients. Item views and the attention set are computed from
  several rows, so a command's events don't map onto the entities it changed. Events stay with
  their job for history and audit, while the feed needs only a short window. ADR 0007 left the
  choice here.
- **A version vector per entity.** The client sends the version of everything it holds and the
  server sends what's newer. Without bidi the request carries the whole held set, and the server
  reads the whole scope to compare, which costs a snapshot anyway. Deletions still need
  tombstones, and there's no consistent cut across entities. It does avoid a feed table and a
  window to fall out of.
- **A sequence per scope.** Scopes overlap and the API defines them, so one change would bump many
  counters, and a new scope would need a backfill.
- **The spike's error codes.** Every case has the same recovery, so an error adds a round trip and
  a second path in each client.
- **An epoch minted only on restore.** It saves a reset after a plain restart, but depends on
  detecting every restore and misses a file copied in by hand. Resets are cheap because scopes are
  bounded.
- **Text still streaming on the transcript stream.** It's a field-level patch, it would fan out
  before the writer commits, and nothing could resume it.
- **One stream with a changeable set of scopes.** It needs bidi, which ADR 0003 rules out, or
  unary calls that change a live stream's scopes, which means per-stream server state and ordering
  between those calls and the stream.
- **The control-plane spec's feed.** Its `changes` rows store each delta's document or a field
  patch at commit. Patches are what the roadmap rules out, and a stored document duplicates the
  entity and fixes its rendering at commit time. Its one socket with subscribe and unsubscribe
  messages is what ADR 0003's server streams replace.

## Consequences

- Job 2.2 adds the change-feed table, the `changeSeq` counter, the epoch written by
  `server.started`, the feed position on receipts and the pruning timer.
- Job 2.3 builds `Subscribe`: change rows derived from state writes and view dependencies, with a
  contract test that every streamed table's writes yield their change rows; consistent-cut
  batches; paging; heartbeats; resets; and the stream registry with its revocation close. Its e2e
  test resumes with a cursor inside the window, which replays exactly the gap, and with one below
  it, which gets a snapshot, with no duplicate or missing entity. That covers the reset paths the
  spike left untested.
- Jobs 1.7 and 2.6 bind streams to credentials and end them on revocation, expiry and scope
  change. Job 2.6's "a revoked one stops within one request" covers streams.
- Job 3.1 keeps the per-transcript `generation` in the transcript store, and job 3.6 builds
  `SubscribeTranscript`. Every restart, every redaction and every deletion dc orders resets the
  transcript streams it affects to their last page and drops their cached items. Job 3.6 and the
  retention and redaction policy weigh how often that happens.
- Jobs 3.8 and 3.9 keep cursors per profile and scope, apply batches whole, reconnect with backoff,
  stop on terminal codes, cache only subscribed data and set the bound after which data that isn't
  reopened is dropped. Job 3.9 adds the foreground reconnect the spike's Kotlin client lacked.
- The retention policy sets the feed's window. The performance budgets set the heartbeat and the
  page, batch and snapshot caps, and carry the control-plane spec's per-paint target: under 100 KB
  on a 60-subagent fixture. The API conventions ADR defines page tokens for history and every error
  code beyond the Connect codes named here.
- The interaction model's entities stream under this ADR.
- Making events the cursor, sending text still streaming, subscribing over bidi, or keeping
  cursors across an epoch needs an ADR that supersedes this one.

## Security

This touches T1 × B1, T2 × B1 and T3 × B1.

- **I10 (T1 × B1):** revoking a device ends its open streams. No batch read after the revocation
  commits, and no transcript item checked after it, is sent. An expired credential ends streams
  too.
- **I8 (T1 × B1, T3 × B1):** `Subscribe` and `SubscribeTranscript` authenticate the caller when the
  stream opens, and the stream stays bound to that credential.
- **I9 (T3 × B1):** streams use the same channel as every call (ADR 0003). A replayed or altered
  cursor changes only which part of its scope the authenticated device is sent, and grants
  nothing.
- **I2 (T2 × B1):** a gate is sent whole within one batch, and `ApproveGate` binds the revision
  the client shows, so an approval of a stale revision is refused
  ([ADR 0004](0004-gate-state-machine.md)).
- **I16 (T2 × B1):** streamed entities and items carry untrusted content as data, which clients
  render as inert text.
- **I11:** unaffected. Streams carry no commands.
- **A9:** `removed` entries and resets purge deleted and redacted data from client caches that
  are reopened, and cached data that isn't reopened is dropped after a bound.
- **Separate profiles:** random epochs and per-profile cursors give no server a way to link a
  client to another server.

R1 and R2 stand. The threat model is unchanged.
