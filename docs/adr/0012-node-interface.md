# 0012. Node interface

- Status: Accepted
- Date: 2026-11-27

## Context

Job 2.1 writes the first code in `server/src/`, and job 3.1 builds the node interface, so the
boundary between them has to be fixed before either starts. The constraints:

- **The roadmap's Control-plane spec decision.** The core addresses repos by `projectKey` and
  machines by `nodeId`, `local` in v1, and reaches git, files and runtimes only through an
  in-process node interface, enforced by a lint rule that the core never imports them.
  Multi-machine nodes are a v1 non-goal; the boundary stays so they can come later.
- **[ADR 0006](0006-ids.md)** says the node interface takes `projectKey` and `nodeId`, that
  checkout directories are named from IDs, and that a `projectKey` never becomes a path.
- **[ADR 0009](0009-transcript-store.md)** says this ADR carries transcript items with their
  `transcriptId` and `itemKey`.
- **[ADR 0007](0007-command-event-outbox.md).** Decide is pure, nothing acts before its command
  commits, effects and probes do the I/O, and a pin is consumed by a command that commits before
  the tool-call gate returns allow.
- **[ADR 0001](0001-toolchain.md)** chose ESLint's built-in `no-restricted-imports`, scoped with
  `files`, for the rule.
- **A rule with no code to check passes vacuously.** `server/src/` holds only `index.ts`.

Outpost's control-plane spec (`docs/superpowers/specs/2026-11-05-control-plane-design.md`, §1, §3
and Phase 3) is the requirements source, not a template. Its control plane does no git, files or
model work and its node does all of it, which is the split kept here. Its WebSocket frames,
epochs, registration and resync served remote nodes, which v1 doesn't have.

This ADR doesn't decide request kinds, the session lifecycle or the runtime adapters (job 3.1),
the tool-call gate's request and decision (job 1.8), checkouts and the GitHub client (job 3.5),
or per-kind deadlines and size caps (the performance budgets).

## Decision

- **`server/src/` is core, except three directories** that may reach the host: `storage/`,
  `host/` and `local-node/`.
- **Core reaches git, checkouts, repo files, processes and runtimes only through the node
  interface,** whose types live in `node/`. The database files are `storage/`'s. `host/` injects
  the config, secrets, TLS material and log sinks core uses; core never imports `host/`.
- **Core to node is typed async request and response,** carrying plain data.
- **Node to core is three handlers** the core registers: tool-call decisions, session commands
  and session events.
- **The lint rule ships now,** in `eslint.config.js`, with a test that lints synthetic files so
  it is checked before any core code exists.

### Directories in `server/src/`

| Directory     | Holds                                                                                                                  | Job            |
| ------------- | ---------------------------------------------------------------------------------------------------------------------- | -------------- |
| `node/`       | The node interface: its types, `NodeError` and `nodeId`. It is core                                                    | 3.1            |
| `local-node/` | The `local` node: git, checkouts, files, runtime adapters and the session callback channel                             | 3.1, 3.5, 4.12 |
| `storage/`    | The SQLite driver and database files: the domain database, the transcript store, backup, restore and migrations        | 2.1            |
| `host/`       | The entrypoint and composition root, bootstrap config, secret providers, TLS material, log sinks and process lifecycle | 2.4            |
| Anything else | Core: decide, the bus, effect and probe workers, RPC handlers and policies                                             | 2.2 onward     |

`server/src/index.ts` is unchanged; job 2.4 puts the server's entrypoint in `host/`.
`server/test/` and `cli/` are outside the rule. `server/src/` holds only `.ts` and `.mts` files:
lint covers both and refuses `.cts` and `.tsx` files, since the import rule can't see a `.cts`
file's `require` and no boundary block covers `.tsx`.

### What each directory may import

| Directory     | Files | Processes | SQLite | Runtime SDKs | Loader bypasses | May not import         |
| ------------- | ----- | --------- | ------ | ------------ | --------------- | ---------------------- |
| Core          | no    | no        | no     | no           | no              | `host/`, `local-node/` |
| `storage/`    | yes   | no        | yes    | no           | no              | `host/`, `local-node/` |
| `host/`       | yes   | yes       | no     | no           | no              | none                   |
| `local-node/` | yes   | yes       | no     | yes          | yes             | `host/`, `storage/`    |

- **Files** are `fs` and `fs/promises`, **processes** `child_process`, `cluster` and
  `worker_threads`, each with or without `node:`, and **SQLite** is `node:sqlite`. **Loader
  bypasses** are `module`, dynamic `import()`, and `getBuiltinModule`, `binding` and `dlopen` on
  `process`.
- **Runtime SDKs** are listed by package. The list starts with `@anthropic-ai/claude-agent-sdk`.
  **The PR that adds a dependency that reaches git, files, processes or a runtime adds it to the
  rule,** such as a SQLite driver other than `node:sqlite` in job 2.1 and the Codex, Cursor and
  ACP packages in job 4.12.
- **Network modules aren't restricted.** Core may use `node:http2`, `fetch` and HTTP clients for
  external services, as ADR 0007's effects run with the server's own GitHub and source clients.
  Job 3.5 decides whether GitHub goes through `gh`, a process and so the node, or the API.
- **The rule catches drift, not malice.** A compromised dependency in the server process owns
  everything (threat model §4, T4). Three rules are left to review: an exempt directory exports
  only its own domain API, never a general file or process helper that would launder the boundary;
  `host/` runs no git and no runtime; and `local-node/` imports nothing from `server/src/` but
  `node/` and the core's pure helpers, never a module that reaches storage, and uses dynamic
  `import()` only for runtime SDKs.
- Each exempt directory's config block restates the rule's full options, since a later flat-config
  block replaces them. A block added later that sets one of these rules on `server/src/` repeats
  the boundary entries. `scripts/node-boundary.test.mjs` lints a sample file in core and in each
  exempt directory, so a block that stops matching or loses its options there fails it.

### Core to node: requests

| Field        | Meaning                                                                                             |
| ------------ | --------------------------------------------------------------------------------------------------- |
| `nodeId`     | `local` in v1. Any other value is refused with `invalid` (ADR 0006)                                 |
| `kind`       | Namespaced, such as `project.*`, `checkout.*`, `git.*`, `file.*`, `session.*` or `transcript.*`     |
| `projectKey` | For anything about a repo. Never a path                                                             |
| `checkoutId` | For anything inside a checkout. A TypeID whose prefix job 3.5 names; the node derives its directory |
| `body`       | Plain data, defined by the job that adds the kind                                                   |
| `deadline`   | An absolute time from the injected clock. The performance budgets set each kind's default           |

- A request also takes an `AbortSignal`, which is an option and not data. Aborting cancels it.
- **Plain data** is strings, numbers, booleans, null, arrays, plain objects and `Uint8Array`, so
  a later transport can encode it as JSON or Protobuf. No function, class instance, stream, handle
  or promise crosses, in either direction.
- **Expected outcomes are results, not errors,** as in [ADR 0011](0011-api-conventions.md): a
  merge conflict, a missing file or a rejected push. A request rejects only with a `NodeError`,
  and the local node converts any other thrown value to one, so no stack leaves it as data.
- `NodeError` has one of these codes:

| Code                | When                                                             |
| ------------------- | ---------------------------------------------------------------- |
| `invalid`           | Bad arguments, an unknown `nodeId`, or a malformed path or ID    |
| `not_found`         | An unknown `projectKey`, checkout or session                     |
| `unavailable`       | The node is shutting down                                        |
| `cancelled`         | The request was aborted                                          |
| `deadline_exceeded` | The request outlived its deadline                                |
| `failed`            | The host refused, such as an unexpected git exit or a disk error |
| `internal`          | Anything else                                                    |

- `message` is diagnostic English for logs. It never carries a credential and is never parsed. A
  `NodeError` never reaches a client as it is; the RPC layer maps it to ADR 0011's codes, mostly
  `internal` or `unavailable`.
- **A kind that changes anything outside the process is idempotent on its body:** repeating it
  adopts what is already done, as ADR 0007's already-done checks do. After `cancelled`,
  `deadline_exceeded`, `unavailable` or `internal`, such a request's outcome is unknown, and the
  caller retries it only through that idempotency. `session.send` carries its input's ID, and job
  3.6 makes delivery idempotent on it.
- **Results are bounded.** Large content, such as a file, a diff or a runtime's transcript file
  for import, is read in ranges or pages, never whole ([ADR 0008](0008-storage-shape.md)).
- **Paths.** A request names files by repo-relative path, and the node validates it: no `..`, and
  symlinks resolved inside the checkout. No request field or body the core builds addresses the
  host by absolute path, except a project's registered path, when the core registers a project or
  sends the node its project list at boot. A request to import a runtime's transcript file names it
  by runtime and runtime session ID, and the node resolves the path. Item bodies and the call in
  `decideToolCall` can hold absolute paths the runtime used; they are untrusted content (I16), and
  the core never turns one into a host path.
- **No credential crosses as data.** The node gets its credentials from `host/` when it is built.
- Requests have no order between them, so a caller awaits one `session.send` before sending the
  next to the same session. The concurrency policy limits how many run.

### Node to core: handlers

`host/` builds the node, passing it the handlers the core provides and its credentials, and gives
the core the node through the interface type in `node/`. The node may import the core's pure
helpers, such as the TypeID helper, but reaches the core's state and decisions only through the
handlers.

| Handler          | Shape                                              | Rule                                                                      |
| ---------------- | -------------------------------------------------- | ------------------------------------------------------------------------- |
| `decideToolCall` | Request and response, with the node's own deadline | Fails closed: a rejection, a timeout or no handler denies the call        |
| `submit`         | Request and response, returning a receipt          | A session command from the callback channel                               |
| `onSessionEvent` | One way, ordered per session                       | The next event for a session is delivered only after the last one settles |

- **Tool-call decisions come from the core,** because a pin is consumed by a command that commits
  before allow (ADR 0007), and the node can't reach storage. Job 1.8 designs the call and the
  decision.
- **`submit` takes its session from the channel.** The node sets `sessionId` from the callback
  channel's authentication, never from the payload, and passes the runtime's tool-call ID, which
  ADR 0007 deduplicates on.
- **A rejected session event ends the session.** The core retries what it can before rejecting, so
  no item is dropped silently.

Session events:

| Event               | Body                                                                                             |
| ------------------- | ------------------------------------------------------------------------------------------------ |
| `transcript.opened` | `transcriptId`, and for a subagent its parent's `transcriptId` and the `itemKey` that started it |
| `item`              | `transcriptId`, `itemKey`, `at`, `kind`, `v` and `body`: one whole, completed item (ADR 0009)    |
| `status`            | `working` or `idle`                                                                              |
| `exited`            | Why: `completed`, `failed`, `interrupted` or `host_error`                                        |

- The core passes a session's main `transcriptId` in `session.start`. The node mints a
  subagent's `trn` ID with the shared TypeID helper, so the server still mints it (ADR 0006).
- **No text still streaming crosses.** Clients see an item once it is whole
  ([ADR 0010](0010-subscriptions-cursors.md)).
- The node assigns no `seq`; the transcript writer does (ADR 0009), and `itemKey` makes a
  repeated item a no-op.
- This ADR reads ADR 0009's "session's adapter" as two halves. The runtime adapter in
  `local-node/` turns runtime frames into items. The core's consumer of `item` events derives
  facts and records them as `server` commands. Job 3.1 names both.
- Sessions are long-lived and aren't requests. `session.start`, `session.send`,
  `session.interrupt` and `session.close` are requests that resolve once the node has acted, not
  when the turn ends. `interrupt` stops the current turn and `close` ends the process.

### Under ADR 0007

- **Decide never calls the node.** Node calls happen outside command transactions: in effect and
  probe workers, in read handlers such as diff and file views, and to start, message and stop a
  session once the command that asks for it commits. Outcomes return as `server` commands, such
  as effect and probe results and derived facts, or as `session` commands through `submit`.
- **The node holds no domain state.** It holds host state that domain records describe:
  checkouts on disk, runtimes' resume files, live processes, and a cached copy of the project
  list. `server.started` reads only the database.
- **The node is in-process,** so a restart ends its sessions, and invariant xii applies. Nothing
  reconnects or resyncs in v1.
- **`local-node/` can't import `storage/` directly,** and review keeps its imports from
  `server/src/` to `node/` and the core's pure helpers, so no runtime adapter or session holds a
  database handle.

### Absolutes and their exceptions

| Rule                                                            | Exceptions                                                                                                                                                                                                      |
| --------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Core never imports file, process, SQLite or runtime modules     | `storage/`, `host/` and `local-node/`, as the import table says. Network modules aren't restricted                                                                                                              |
| No request field or body the core builds holds an absolute path | A project's registered path, at registration and in the project list sent at boot. Item bodies, the call in `decideToolCall` and a `NodeError`'s logged `message` may hold one, as untrusted or diagnostic text |
| Every request has a deadline                                    | A session's lifetime isn't a request. `submit` and `onSessionEvent` have none; `decideToolCall` has the node's                                                                                                  |
| The node holds no domain state                                  | It holds host state: checkouts, runtimes' resume files, live processes and a cached project list                                                                                                                |
| Decide never calls the node                                     | None                                                                                                                                                                                                            |
| The node never reaches storage                                  | None. Lint blocks the direct import and review the indirect one. Items reach the transcript writer through `onSessionEvent`, and import reads runtime files through node requests                               |
| No credential crosses as data                                   | None. The node's credentials come from `host/` when it is built                                                                                                                                                 |
| Only `local` is a valid `nodeId` in v1                          | None                                                                                                                                                                                                            |
| A request rejects only with a `NodeError`                       | None. The local node converts every thrown value                                                                                                                                                                |

## Alternatives

- **A message protocol now,** as the control-plane spec's §3 designs: tagged frames with message
  IDs, epochs, acks, registration and resync. That machinery serves a boundary between processes,
  which v1 doesn't have, and ADR 0007 drops epochs. Keeping every body plain data leaves the
  protocol possible later without changing callers.
- **One interface per capability,** such as git, files and runtimes. Three seams with no one
  place for `nodeId` routing, deadlines, cancellation and errors, and three things to carry over a
  transport later.
- **Node calls as commands on ADR 0007's bus.** Reads such as diffs would pay for receipts and
  events, and node calls already happen in effects and probes after commit.
- **Restricting only a `core/` directory.** A new directory would be unchecked by default. Here a
  new directory is core until `eslint.config.js` exempts it, which shows in review.
- **Core as its own workspace package without `@types/node`,** so a `node:fs` import fails to
  typecheck. A stronger check, but core needs `node:crypto` and `node:http2`, and splitting
  packages before any code exists is premature. A later ADR can adopt it.
- **An import-boundary plugin,** such as `eslint-plugin-import-x`'s `no-restricted-paths` or
  `eslint-plugin-boundaries`. They resolve real paths, but add a dependency and resolver
  configuration for what a regex on the import specifier already expresses. The license check
  wouldn't stop one, since it reads production dependencies only.
- **`@typescript-eslint/no-restricted-imports`.** It adds `import = require`, which `server/src/`
  can't use: its `.ts` and `.mts` files are ESM under `verbatimModuleSyntax`, and lint refuses
  `.cts`. It also adds an option to allow type imports, which isn't wanted.
- **dependency-cruiser.** A second tool and a new CI job, where job names are a stable contract
  (ADR 0001).
- **Deferring the rule to job 2.2 or 3.1,** as ADR 0001's Context expected. Code written before
  then would land unchecked, and the directory layout would be decided later by whoever wrote it
  first.

## Consequences

- `eslint.config.js` carries the rule, and `scripts/node-boundary.test.mjs` checks it on a sample
  file in core and in each exempt directory. It ships in job 1.5, not 2.2 or 3.1 as ADR 0001's
  Context expected; that is Context, not a decision, so nothing is superseded.
- Job 2.1 puts the SQLite driver and database files in `storage/`. Its TypeID helpers are the
  first production code the rule checks.
- Job 2.4 puts the entrypoint, config, secrets, TLS and logging in `host/`.
- Job 2.2's effect worker is the first core code with a reason to reach the host, and does so
  through the node.
- Job 3.1 defines the request kinds, the session lifecycle and `NodeError` in code, builds the
  runtime adapters and the session callback channel in `local-node/` and the core's item
  consumer, and confirms the Agent SDK entry in the rule.
- Job 3.5 adds checkout and git kinds, names the checkout prefix, and chooses `gh` or the API.
- Job 1.8 designs `decideToolCall`'s call and decision. Job 3.6 makes `session.send` idempotent.
- Job 4.12 adds each runtime's packages to the rule.
- The performance budgets set each kind's default deadline and result size cap.
- Exempting another directory, core importing a restricted module, anything but plain data
  crossing the interface, the node reaching storage, decide calling the node, or a node on another
  machine needs an ADR that supersedes this one.

## Security

This touches T2 × B2, T2 × B4 and T4 × B2. I2, I7, I15 and I16 are cited below as constraints on
the interface, not as cells it touches.

- **I1 (T2 × B2, T4 × B2):** `decideToolCall` denies when it rejects, times out or has no
  handler.
- **I13 (T2 × B2):** the node sets a session command's `sessionId` from the callback channel's
  authentication, never from the payload, and validates IDs and repo-relative paths before they
  reach a path or argv (T2.5).
- **I14 (T2 × B4):** `local-node/` can't import `storage/` directly, and review keeps its imports
  from `server/src/` to `node/` and the core's pure helpers, so no session or runtime adapter
  holds a database handle.
- **I3 (T2 × B2, T4 × B2), I2:** the core decides scope and approvals, and the node runs exactly
  the call it is given.
- **I4, I5, I6:** unaffected. The interface adds no grant, mode or Bypass path.
- **I7:** no credential crosses in a body, a result or a `NodeError` message.
- **I15:** a kind that changes anything outside the process is idempotent on its body.
- **I16:** results are data.

R1 and R2 stand. The threat model is unchanged: the interface is inside the server process, so B2
stays where it is. A node on another machine would add a boundary and update the threat model.
