# 0013. DB migrations

- Status: Accepted
- Date: 2026-11-27

## Context

Job 2.1 builds backup, restore and migrations, and earlier ADRs left how migrations run to this
policy. The constraints:

- **The roadmap's 1.5 bullet:** DB migrations are forward-only, and back up first.
- **[ADR 0007](0007-command-event-outbox.md):** nothing writes a domain table outside a command
  transaction, and schema migrations are the migrations policy's.
- **[ADR 0008](0008-storage-shape.md):** promotion, demotion and rewriting migrations run in
  server code, in keyset pages, through the validating write path, finish before the server serves
  reads and resume after a crash. JSON that is never rewritten after commit is never migrated. The
  migrations policy decides the rest.
- **[ADR 0009](0009-transcript-store.md):** the migrations policy covers both SQLite files, and
  backup and restore treat them as a pair.
- **[ADR 0012](0012-node-interface.md):** `storage/` owns the database files and migrations.

Outpost's `src/db/migrate.ts` is requirements, not a template. It applies numbered
`NNNN_name.sql` files in order, one transaction each, and records each in
`schema_migrations (version, name, checksum, applied_at)`. It refuses to start when the database
has a migration the build doesn't know, or when an applied file's checksum changed. It takes no
backup and has no migrations in code.

This ADR doesn't decide the backup mechanism, the restore command or where backups are stored (job
2.1), or how long backups are kept ([ADR 0014](0014-retention-redaction.md)).

## Decision

- **Forward-only.** Released migrations are never edited, except a data migration that can't
  finish (below), and there are no down migrations.
- **At boot only,** before anything is served.
- **A verified backup of both files comes first.**
- **Two kinds:** SQL schema migrations and ADR 0008's data migrations in server code.
- **A failed, unknown or changed migration refuses start.**
- **A downgrade is a restore** of the backup taken before the newer build migrated.

### Scope and timing

- Migrations cover both SQLite files: the domain database and the transcript store. Each has its
  own ordered list and its own `schema_migrations` record, in that file.
- `storage/`'s migration runner is the only code that changes a schema.
- They run at boot, before `server.started` (ADR 0007) and before any read or command is served.
  Until they finish, every RPC but the health check gets `unavailable`
  ([ADR 0011](0011-api-conventions.md)). The health check reports only a coarse state, such as
  starting, migrating or serving, and `majula doctor` on the host shows the detail.
- No CLI command or second process applies migrations: one process owns the files (ADR 0007). A
  later job may add a read-only report of pending migrations to `majula doctor`.
- The `server.started` that follows mints a new epoch, which resets clients' streams
  ([ADR 0010](0010-subscriptions-cursors.md)).

### Forward-only

- Migrations are numbered in order. Once released, a migration is never edited, renumbered or
  deleted, and a mistake is fixed by a new migration. A data migration that can't finish is
  the exception, below.
- The checksum of each schema migration is recorded when it applies. A database whose recorded
  checksum differs from the build's refuses start. A data migration records its version ID when it
  applies.
- CI fails a pull request that edits or deletes a migration that exists on `main`, except an edit
  to a data migration that adds a new version ID. Job 2.1 adds the check to the existing `test`
  job, so no CI job name changes.

### Schema and data migrations

- **A schema migration** is SQL, applied in one transaction together with its `schema_migrations`
  row.
- **A data migration** is ADR 0008's promotion, demotion or rewrite of rewritten JSON. It runs in
  server code, in keyset pages, through the validating write path, and records its keyset position
  after each page, so it resumes from there after a crash. It is recorded as applied only when its
  last page commits.
- A data migration is idempotent per row. When a released data migration can't finish, a later
  build may replace it under the same number with a new version ID, and restarts it from its first
  page. A database that recorded any version of it as applied treats it as applied.
- Migrations run outside the command bus and write no receipts, events or change rows. Schema
  migrations are the exception ADR 0007 names, and ADR 0008's data migrations also run outside
  commands.

### What a migration doesn't touch

- No migration edits or deletes rows of JSON that is never rewritten after commit (ADR 0008): event
  bodies, receipt results, timer JSON, outbox payloads and gate artifacts. A column added to those
  tables is filled only for rows written after it, as ADR 0008 says.
- No migration deletes history. Removing data is ADR 0014's retention.

### Backup first

- Before a run of pending migrations starts on either file, the server backs up both files as a
  pair (ADR 0009) through job 2.1's backup mechanism, and checks that the copy opens and passes
  SQLite's integrity check.
- A restart that resumes an unfinished data migration takes no new pair. The pair taken before its
  run started stays the way back.
- A new database with no applied migrations has nothing to back up and takes no pair.
- If the backup fails, or free disk space is too low for it, the server migrates nothing, refuses
  start and says why.
- ADR 0014 sets how long these backups are kept.

### Failure and downgrade

- **A failed schema migration** rolls back, so its file stays at the previous version.
- **A failed data migration** keeps its committed pages and position, and nothing is served until
  it completes.
- Either way the server refuses start, logs the migration and its error, and `majula doctor`
  reports it. Nothing restores automatically. dc either installs a build that fixes the migration
  or restores the pre-migration pair and runs the older build.
- **A database with a migration the build doesn't know** refuses start and names the newer
  version. The way back is the backup pair taken before that migration, which loses what was
  written since. Restore is job 2.1's, and it warns about this. Once ADR 0014 has deleted that
  pair, there is no way back to the older build.
- An older build runs unchanged on a database with no migration it doesn't know, which is the
  downgrade ADR 0011 allows for.

### Absolutes and their exceptions

| Rule                                                               | Exceptions                                                                                                                                   |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Migrations run only at boot, before anything is served             | The health check, which reports a coarse state                                                                                               |
| Only `storage/`'s migration runner changes a schema                | None                                                                                                                                         |
| A released migration is never edited or removed                    | A data migration that can't finish may be replaced under its number with a new version ID                                                    |
| Every migration run is preceded by a verified backup pair          | A new database with no applied migrations, which has nothing to back up. A resumed data migration uses the pair taken before its run started |
| Migrations write no receipts, events or change rows                | None. Schema migrations are ADR 0007's named exception, and data migrations run outside commands under ADR 0008                              |
| No migration edits or deletes rows of JSON that is never rewritten | None. A column that only later rows fill may be added (ADR 0008)                                                                             |
| An unknown, changed or failed migration refuses start              | None                                                                                                                                         |

## Alternatives

- **Down migrations.** Rarely exercised, so they fail when needed, and they can't bring back data a
  migration removed. A restored backup can.
- **Migrations as commands on the bus.** Schema work would get receipts and events, and the bus
  would have to run on a schema it hasn't migrated yet.
- **A separate `majula migrate` step.** A second process on the files, and an upgrade that can
  boot half-migrated.
- **Backing up only before some migrations.** The migration that wasn't backed up is the one that
  fails.
- **Outpost's runner as it stands.** Its checksums and refusals are kept. It has no backup and no
  data migrations, which ADR 0008 needs.

## Consequences

- Job 2.1 builds the runner for both files, data-migration progress and resume, the pre-migration
  backup pair and its integrity check, the CI check that released migrations don't change, and
  restore's warning.
- Job 2.4's health check and `majula doctor` report migration state.
- Job 7.1's self-update relies on migrations running at boot.
- Down migrations, migrating without a backup, or a migration that rewrites JSON that is never
  rewritten needs an ADR that supersedes this one.

## Security

This touches T2 × B4.

- **I14 (T2 × B4):** backups hold A9 and encrypted credentials at rest. They have the database
  files' permissions, live in the server's data directory, and are outside every action's file
  scope.
- In the spirit of I1, an unknown, changed or failed migration refuses start rather than serving
  from a schema the build doesn't match.
- **I2:** no migration rewrites an approved payload (ADR 0008).
- **I17:** migrations ship only through reviewed pull requests, and CI refuses an edit to a
  released one.

R1 and R2 stand. The threat model is unchanged.
