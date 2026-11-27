# 0008. Storage shape

- Status: Accepted
- Date: 2026-11-26

## Context

Job 2.1 designs the storage layer and every later job adds tables, so the shape they share has to
be fixed first. The roadmap's constraints:

- **Database.** SQLite only. Postgres existed for a shared server, which is now an anti-goal.
- **The 1.5 bullet** asks for relational tables with indexed columns plus JSON payloads, paginated
  queries, and never loading everything at boot.
- **One person per server.** An earlier version of the bullet also asked for workspace scoping on
  every query, ready for Postgres row-level security. [ADR 0006](0006-ids.md) removed tenancy and
  SQLite has no row-level security, so both are dropped.

Outpost is requirements, not a template. Its storage shows what to avoid:

- `src/db/migrations/sqlite/0001_init.sql` keeps every collection in one generic
  `rows (collection, key, doc)` table, with nothing typed or indexed outside the key.
- `src/db/backend.ts` declares `loadAll()`, whose `Snapshot.rows` is every row of every collection,
  and `src/db/adapters/sql.ts` reads them in one query.
- `src/work/work-queue.ts` reads every job file into memory at boot, re-migrates each record in
  memory on every boot, and skips a file it can't parse.

Its `scanEvents`, `scanChanges` and `scanSessionOutput` are bounded, keyed range reads, and are the
shape worth keeping. The roadmap names Outpost's `src/db/` contract a candidate design for job 2.1;
this ADR leaves its commit primitive, fault points and range scans as candidates and rules out the
`rows` table and `loadAll`.

This ADR doesn't decide tables (job 2.1 and the jobs that add them), the transcript store (the
domain storage and transcript store ADR), page tokens and stream cursors (the API conventions and
subscription ADRs), or migrations, retention, performance budgets and concurrency limits (the 1.5
policies).

## Decision

### Tables and columns

- Domain records live in typed `STRICT` tables, one per record type. There is no generic table of
  documents.
- **A field is a column when any of these holds:**
  - It is the record's ID or a reference to another record, such as `projectId`, `jobId`, a
    parent's ID or `nodeId`.
  - A query reads it in `WHERE`, `JOIN` or `ORDER BY`, or a constraint covers it, such as
    `projectKey`'s uniqueness (ADR 0006) or the state restart recovery selects on.
  - It is the entity's `version` ([ADR 0007](0007-command-event-outbox.md)) or a seq.
- **Every other field goes in a JSON column**, named for its role, as ADR 0007 names an event's
  `body`, an outbox row's `payload` and `result`, and a receipt's `result`. A field that a
  command's decide step only compares, after reading one row by its key, isn't a query field: a
  gate's `revision` (ADR 0004) can stay in the gate's JSON.
- **One home per field.** In any row, a field is a column or a JSON field, never both. No runtime
  query or index reads a JSON path, through `json_extract`, `->`, `->>` or a generated column.
- **Promotion out of rewritten JSON.** When a field of rewritten JSON becomes a query field, one
  migration adds the column, fills it from each row's JSON and removes the field from the JSON.
  Demotion is the reverse. The migration runs in server code, in keyset pages, through the
  validating write path. It finishes before the server serves reads, and resumes after a crash.
- **Promotion out of JSON that is never rewritten.** The column is filled only for rows written at a
  new schema version, whose JSON leaves the field out. Older rows keep it in their JSON at their
  version, are read as before, and can't be selected by the new column. Such a column is never
  demoted.
- IDs are `TEXT` (ADR 0006), times `INTEGER` milliseconds since the Unix epoch in UTC, booleans
  `INTEGER` 0 or 1, closed enums `TEXT` with a `CHECK`, and JSON `TEXT` holding one object.
- No table has a tenant, owner or workspace column (ADR 0006).

### JSON and its versions

- Each JSON column has a schema in server code, chosen by the row's kind and version where it has
  them. The storage layer validates JSON against it on write and parses it on read. A row that
  fails to parse is an error naming its table and key, never skipped.
- **JSON that is rewritten**, such as a state row's JSON and an outbox row's `result`, has one
  current shape per column. Adding an optional field needs no migration. Any other change, such as a
  rename, a removal, a type change or a new required field, is a migration that rewrites every row
  of the table the same way. Nothing upcasts these rows on read.
- **JSON that is never rewritten after commit** carries its schema version beside it, as an
  event's `v` does, and its readers keep reading every version still stored. No migration rewrites
  it. This covers an event's `body`, a receipt's `result`, a timer row's JSON, an outbox row's
  `payload` in every state, and a gate's artifact at each revision, so a migration never changes
  what a draft shows or an approved write sends.
- JSON holds no plaintext credential (I14), and an outbox row's `payload` and `result` hold no
  credential at all (ADR 0007).

### List queries

- **Every list query is a keyset query.** It orders by a unique key: a seq, an ID or a tuple ending
  in one. It takes a `LIMIT`, which the storage layer caps, and continues from the last row's key
  (`WHERE (k1, k2) > (?, ?)`), never by `OFFSET`. An index whose leading columns are the query's
  equality filters, followed by its order key, serves it. Reading one row by a primary or unique
  key isn't a list query.
- An ID orders by creation time only to the millisecond (ADR 0006), so a list that needs strict
  creation order keys on a seq.
- Reading every child of one parent, such as the steps of a job the 1.4 interaction model shows
  fully loaded, is a keyset query on the parent's ID, taken in pages until it runs out.
- A page token on the wire is the API conventions ADR's, and a stream cursor the subscription
  ADR's. This ADR fixes only the query behind them.

### Nothing loads a whole table

- No code path reads a table that grows with history or use, or all of history, into memory. A
  table whose rows dc creates by hand, such as projects, and that no job, session or event grows,
  may be read whole in keyset pages.
- At boot, and in its loops that find work to run (recovery, dispatch, effects and timers), the
  server selects rows only through bounded selections on indexed columns, such as what
  `server.started` (ADR 0007) needs, the effect worker's pending outbox rows and due timers. Those
  sets grow with active work, not with history. A table that may be read whole, as above, may also
  be read at boot.
- Maintenance sweeps that read rows into server code, such as retention and export, walk history
  only in capped keyset pages. How backup copies the database file is job 2.1's.
- Caches, which ADR 0007 rebuilds from committed rows, fill on demand or from the same bounded
  queries, never by scanning history.

## Alternatives

- **A fully normalized schema.** Every field a column and nested structures as child tables. Most
  fields are never queried, so every shape change becomes DDL, and decide reassembles each entity
  from joins.
- **A document store in SQLite JSON, as Outpost has.** Keys, references and uniqueness hide in
  JSON paths, outside the schema, and the indexes that matter become expressions. Nothing is cheap
  to query by, so the natural reader loads everything.
- **Generated columns over JSON.** One source per field, but a queried field gets two names and a
  type set by a JSON path, and promoting it still takes a migration. A plain column gives the same
  index more simply.
- **Upcasting on read, as Outpost's job store does by inspecting each record's shape.** Several
  shapes coexist indefinitely and every reader carries every upcaster. With a per-row version it
  suits rows never rewritten, so events keep one.
- **`LIMIT` and `OFFSET`.** Skipping is linear in the offset, and rows inserted between pages cause
  duplicates or gaps.

## Consequences

- Job 2.1's storage layer offers point reads by key and capped keyset list reads, with no read-all
  primitive. It validates JSON on write and fails on a row it can't parse. Its contract suite
  checks that boot reads don't grow with a seeded history and that list queries use their indexes.
  It may adopt Outpost's commit primitive, fault points and range scans on merit, but not the
  `rows` table or `loadAll`.
- Job 2.2's receipt, event, outbox and timer tables follow this ADR, and it adds a schema version
  beside a receipt's `result`, an outbox row's `payload` and any JSON a timer row carries.
- The job that designs the gate tables adds one beside a gate's artifact.
- Every design doc that adds a table says which fields are columns and which JSON, and gives each
  list query's order key and index. The spec template asks for this.
- The migrations policy decides the rest of how promotion, demotion and rewriting migrations run.
- The API conventions and subscription ADRs build page tokens and cursors on keyset queries, and
  the retention policy deletes in keyset pages.
- The concurrency limits and performance budgets bound the active set that boot and the server's
  loops select.
- The threat model drops Postgres and the remote database.
- A runtime query or index that reads a JSON path, upcasting rewritten JSON on read, `OFFSET`
  paging, loading a growing table whole or a second database engine needs an ADR that supersedes
  this one.

## Security

This touches T2 × B4, and removes T3's reach of B4.

- **B4:** the database is a local SQLite file, not a network connection, so T3 × B4 becomes `—`,
  and I9 and I14 lose their remote-database clauses.
- **I14 (T2 × B4):** sessions reach state only through commands (ADR 0007), and JSON holds no
  plaintext credential.
- **I16, as a property of the storage shape rather than through these cells:** untrusted content,
  such as a comment or a ticket, is stored as JSON data and parsed against a schema. Queries are
  parameterized, and no JSON path or SQL identifier comes from input.
- **I1, the same way:** a row that fails to parse is an error, so a corrupted gate or approval
  can't silently drop out of a decision.

R1 and R2 stand. The threat model changes with this ADR, as above.
