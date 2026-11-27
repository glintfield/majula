# Architecture decision records

Each ADR records one decision that constrains later work: what was decided, what else was
considered, and what follows from it. Read the index before designing anything that touches a
decision listed here.

Files are named `NNNN-kebab-title.md` and numbered in order. Numbers are never reused or changed.
A superseded ADR stays in place with its status set to "Superseded by NNNN".

To write a new ADR, copy [`template.md`](template.md) and follow the note at its top.

## Index

| ADR                                      | Title                         | Status   |
| ---------------------------------------- | ----------------------------- | -------- |
| [0001](0001-toolchain.md)                | Toolchain                     | Accepted |
| [0002](0002-security-ci.md)              | Security CI                   | Accepted |
| [0003](0003-api-schema.md)               | API schema technology         | Accepted |
| [0004](0004-gate-state-machine.md)       | Gate state machine            | Accepted |
| [0005](0005-session-permission-modes.md) | Session permission modes      | Accepted |
| [0006](0006-ids.md)                      | IDs                           | Accepted |
| [0007](0007-command-event-outbox.md)     | Commands, events, outbox      | Accepted |
| [0008](0008-storage-shape.md)            | Storage shape                 | Accepted |
| [0009](0009-transcript-store.md)         | Transcript store              | Accepted |
| [0010](0010-subscriptions-cursors.md)    | Subscriptions and cursors     | Accepted |
| [0011](0011-api-conventions.md)          | API conventions               | Accepted |
| [0012](0012-node-interface.md)           | Node interface                | Accepted |
| [0013](0013-db-migrations.md)            | DB migrations                 | Accepted |
| [0014](0014-retention-redaction.md)      | Retention and redaction       | Accepted |
| [0015](0015-telemetry.md)                | Telemetry                     | Accepted |
| [0016](0016-performance-budgets.md)      | Performance budgets           | Accepted |
| [0017](0017-concurrency-limits.md)       | Concurrency limits            | Accepted |
| [0018](0018-server-identity-trust.md)    | Server identity and TLS trust | Accepted |
| [0019](0019-pairing-profiles.md)         | Pairing and server profiles   | Accepted |
| [0020](0020-device-credentials.md)       | Device credentials            | Accepted |
| [0021](0021-webhook-intake.md)           | Webhook intake                | Accepted |
