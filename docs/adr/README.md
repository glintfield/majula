# Architecture decision records

Each ADR records one decision that constrains later work: what was decided, what else was
considered, and what follows from it. Read the index before designing anything that touches a
decision listed here.

Files are named `NNNN-kebab-title.md` and numbered in order. Numbers are never reused or changed.
A superseded ADR stays in place with its status set to "Superseded by NNNN".

To write a new ADR, copy [`template.md`](template.md) and follow the note at its top.

## Index

| ADR                                      | Title                     | Status   |
| ---------------------------------------- | ------------------------- | -------- |
| [0001](0001-toolchain.md)                | Toolchain                 | Accepted |
| [0002](0002-security-ci.md)              | Security CI               | Accepted |
| [0003](0003-api-schema.md)               | API schema technology     | Accepted |
| [0004](0004-gate-state-machine.md)       | Gate state machine        | Accepted |
| [0005](0005-session-permission-modes.md) | Session permission modes  | Accepted |
| [0006](0006-ids.md)                      | IDs                       | Accepted |
| [0007](0007-command-event-outbox.md)     | Commands, events, outbox  | Accepted |
| [0008](0008-storage-shape.md)            | Storage shape             | Accepted |
| [0009](0009-transcript-store.md)         | Transcript store          | Accepted |
| [0010](0010-subscriptions-cursors.md)    | Subscriptions and cursors | Accepted |
| [0011](0011-api-conventions.md)          | API conventions           | Accepted |
