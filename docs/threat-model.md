# Threat model

- Status: Living document
- Date: 2026-11-25

This is the threat model every Majula design is checked against. It names what we protect (assets),
where trust changes (boundaries), who attacks (attackers) and the properties every design must keep
(invariants). It states required properties, not designs: job 1.7 (access architecture) and job 1.8
(execution boundary) decide the mechanisms.

**ID rules.** Every asset, boundary, attacker, invariant and residual risk has an ID. IDs are never
renumbered or reused. New items are appended. A retired item keeps its ID with a note saying what
replaced it.

**How to use this document.** A design's Security section lists the matrix cells (§5) the design
touches and, for each invariant that applies there, says how the design keeps it. A design that
adds an asset, a boundary or an attacker updates this document in the same PR.

## 1. Scope and system sketch

Majula is a server that runs agent sessions as jobs with human gates, and native clients that drive
it. v1 has two deployment shapes from one codebase: personal (server on a laptop or one box, local
SQLite) and team-ready (server somewhere shared, remote Postgres).

- **Clients.** SwiftUI for Mac and iPhone, Kotlin and Jetpack Compose for Android. All three
  generate their API code from one schema and render presentation-ready data the server sends.
- **Server.** TypeScript on Node 22. Installed from Homebrew and supervised by launchd
  (`brew services`) on macOS; it also runs on Linux.
- **Agent runtimes.** Claude on the Agent SDK (in-process hooks), Codex, Cursor and generic ACP
  agents. The server detects the runtimes the user has installed and never bundles one.
- **Database.** SQLite (personal) or Postgres (team-ready, possibly on another host).
- **External services.** GitHub; the job sources Linear, Slack, Jira and Monday; MCP servers; model
  providers.
- **Tenancy.** Every record carries a `workspaceId` and an owner `userId`. Credentials and
  integrations are scoped to a workspace or a user. v1 ships exactly one of each. "Workspace" always
  means the tenant; an agent's isolated git copy is a **checkout**.
- **Not in v1.** A push relay, a hosted Majula service and sessions on a machine other than the
  server's. Each would add a boundary, and must update this document when it arrives.

## 2. Assets

- **A1 Source code and checkouts.** Repos and their checkouts on the server host, including
  uncommitted work and private repos. Confidentiality and integrity.
- **A2 Agent-runtime credentials.** Runtime logins and model-provider API keys. Confidentiality.
- **A3 GitHub credentials.** Tokens, OAuth grants and the host's SSH keys. Confidentiality.
- **A4 Push and merge authority.** The ability to change remote state: push, merge, tag or release,
  run workflows, post reviews and comments. Distinct from A3 because it is exercised through an
  approved agent call or the server's own outbox, not only by holding a token. Integrity.
- **A5 Source-integration and MCP credentials.** Linear, Slack, Jira, Monday and MCP OAuth tokens,
  and the write authority they carry. Confidentiality and integrity.
- **A6 Client credentials.** Device keys, session tokens and pairing codes. Confidentiality.
- **A7 Server identity.** The server's long-lived key or private CA, and the key that encrypts
  secrets at rest. Confidentiality.
- **A8 Approvals and grants of authority.** Approvals, write pins, pre-approvals, permission modes
  (including Bypass) and gate decisions. Integrity: a forged or replayed one is an unapproved write.
- **A9 Job and transcript data.** Plans, transcripts, diffs, journals and the rest of the database.
  Confidentiality, including secrets that leak into transcripts.
- **A10 Permission configuration.** Permission groups, action definitions and what each action
  declares. Actions live in the database, so this is data an agent could try to change. Integrity.

## 3. Trust boundaries

- **B1 Client ↔ server.** API calls and streams over a network Majula doesn't control. Pairing
  establishes mutual authentication; the client authenticates the server by a pinned key or private
  CA. Commands, messages and approvals cross inward; job state and transcripts cross outward.
- **B2 Server ↔ agent runtime.** The server starts a session with a prompt, an environment, a
  checkout and grants. Tool calls come back to the gate for a decision, and the agent calls back to
  the server over a local channel. The agent side is untrusted: its next call is controlled by
  whatever content it last read. Any process on the host can reach the local channel, so the
  channel authenticates the session, not the network position.
- **B3 Agent ↔ external services.** Calls an agent makes mid-turn: `git push`, `gh`, MCP tools, web
  fetches and model-provider traffic. Credentials cross outward; untrusted content (repo files,
  tickets, comments, web pages, MCP output) crosses inward.
- **B4 Server ↔ database.** A local file (SQLite) or a network connection (Postgres). Every asset at
  rest crosses it, credentials included.
- **B5 Server ↔ external services.** The server's own calls: polling sources, webhook intake,
  structured writes from its outbox (open or merge a PR, post a reply, source writebacks) and usage
  polling. It is separate from B3 because the server, not an agent, holds these credentials and
  originates these writes.

## 4. Attackers

- **T1 Stolen or lost phone.** Holds a paired device and its credential, possibly unlocked. Targets
  A8 (approve writes, turn on Bypass), A9 (read transcripts) and A6 (extract the credential).
  Reaches B1, and B2 through the server (approvals, Bypass).
- **T2 Prompt injection from a repo or ticket.** Controls content an agent reads (repo files,
  issues, PR comments, tickets, web pages, MCP output) and so, effectively, the agent's next tool
  calls. Targets A1, A3, A4, A5, A8 and A10, and A2 and A9 by exfiltration. Reaches B2 and B3
  directly, B4 through the host filesystem, and B1 and B5 through content the server stores and
  clients render. Its capabilities are T2.1–T2.14 below.
- **T3 Hostile network.** Observes, modifies, replays and drops traffic between clients and the
  server, between the server or agents and external services, and to a remote database. Can
  impersonate the server, reach its listening port and probe unauthenticated routes. Targets A6, A7
  and A9, and A8 by replay. Reaches B1, B3, B4 and B5.
- **T4 Compromised dependency.** Malicious code in an npm package the server or CLI ships, a client
  library, the Homebrew formula or bottle, an MCP server, or a package installed in a checkout. In
  the server process it owns everything (see §8), so the property is keeping it out. Inside a
  session it equals T2 with code execution. As an MCP server it receives credentials and returns
  untrusted output. Reaches B1, B2 and B3.
- **T5 Another user in team mode.** An authenticated member of the same workspace, or of another
  workspace on a shared server. Tries to read others' jobs and transcripts, use another user's
  credentials, approve or message another user's sessions, act in another workspace, or change
  shared actions and permission groups to affect others. v1 ships one user, but these properties
  must hold structurally. Reaches B1, and B2, B3, B4 and B5 through the server and the sessions it
  starts.

### Prompt-injection capabilities (T2.1–T2.14)

Outpost's permission engine refuses each of these except where an entry notes otherwise. Majula's
requirement is refusal (I4 states its one exception). The evidence is an Outpost test suite or
design doc: a source of requirements, not a suite to port.

- **T2.1 Bash argv smuggling.** Chaining a second clause (`;`, `&&`, `|`, `&`); command, backtick
  and process substitution; unbalanced quotes; unquoted expansions that word-split into flags;
  leading assignments that change how a program resolves. Evidence: `allowlist-shell-split`,
  `allowlist-hardening`.
- **T2.2 Flag spelling.** `-d`, `-d=x`, `"-d"`, `-d""` and `-sd` all reach argv as the same flag, so
  a rule that tries to forbid a flag loses. A `.*` guard leaks across a newline or a
  `\`-continuation. Evidence: `permission-group-pull`, `gotchas.md`.
- **T2.3 Writes through redirection.** `>` in a later clause or inside a substitution, a target that
  can't be resolved statically (`$VAR`, `~`, a glob), a leaf or ancestor symlink out of scope.
  Evidence: `allowlist-redirect`, `allowlist-action-scope`.
- **T2.4 Writes and exfiltration through file-referencing flags.** `--body-file ~/.ssh/id_rsa`,
  `--input`, `-F`, `-f k=@path`, curl's `-d @path` and `-T`: the approver sees a path, not the bytes
  sent. Evidence: `allowlist-file-flags`.
- **T2.5 Path traversal and scope escape.** `..`, symlinks, a relative path after a `cd`, a path
  hidden in `--flag=value` or after `--`, a session or branch id that starts with `-` or contains
  path segments. Evidence: `allowlist-fileop-scope`, `allowlist-session-scope`, `gotchas.md`.
- **T2.6 Reads outside declared scope.** A second file beside an allowed one, a process
  substitution, an operand that can't be resolved. Evidence: `allowlist-read-scope`.
- **T2.7 Execution through a read-only grant.** Exec flags and subcommands of read tools, such as
  `sed` beyond a line print or git subcommands that run programs. Evidence: `allowlist-hardening`,
  `permission-group-read`.
- **T2.8 Widening by scope fallback.** Using a broader user-wide or global grant from inside an
  action-bound session. Evidence: `allowlist-confinement`.
- **T2.9 Pin mismatch and payload rewrite.** Running a variant of an approved call (an added flag, a
  reformatted body), swapping a referenced file after approval, spending one approval twice,
  retrying after an interrupt, reaching another session's or dispatch's pin. Evidence:
  `hook-gated-pin`, `engine-gate`.
- **T2.10 Payloads the approver can't see.** A write payload built by command substitution, a
  quoted `$VAR` operand (Outpost only warns on this one), a file outside what the approval card can
  display. Evidence: `gated-allowlist`, `permission-group-push`.
- **T2.11 Gated writes disguised as ungated.** A write-shaped rule placed in an ungated grant, or a
  gated rule that also matches reads. Evidence: `gated-allowlist`, `permission-group-push`,
  `permissions.md`.
- **T2.12 Credential misuse.** Sending a token anywhere but its own service: another host, a
  `--proxy`, `--resolve`, `--connect-to` or `--next` redirect, a position other than the
  `Authorization` header. Evidence: `github-api-curl`, `permissions.md`.
- **T2.13 Gate fail-open.** Making the gate throw or time out; exploiting a runtime's hook semantics
  (exit codes, JSONC comment stripping, an untrusted hook silently dropped); using a tool that never
  reaches the gate (Codex `write_stdin` or web search, Cursor image generation, a working directory
  other than the session's, and ACP reads, which Outpost leaves ungated; see R2). Evidence:
  `gotchas.md`, `permissions.md`.
- **T2.14 Self-escalation and forged callbacks.** Calling a server callback endpoint without the
  session's secret, submitting results for another step, proposing changes to its own action's
  permissions, granting itself a pre-approval, turning on Bypass. Evidence: `hook-server-auth`,
  `engine-gate`, `gotchas.md`, control-plane spec §10 (vii).

## 5. Attacker × boundary matrix

Each cell names the invariants (§6) that must hold where that attacker meets that boundary, and any
residual risk (§7) that weakens one there. `—` means the attacker can't reach the boundary.

|     | B1 client↔server                               | B2 server↔agent                     | B3 agent↔external | B4 server↔DB                    | B5 server↔external            |
| --- | ---------------------------------------------- | ----------------------------------- | ----------------- | ------------------------------- | ----------------------------- |
| T1  | I8, I10, I11 (presence to approve)             | I5, I11 (Bypass needs presence)     | —                 | —                               | —                             |
| T2  | I2 (full payload shown), I16 (inert rendering) | I1, I3, I4, I5, I6, I13, R2         | I2, I7, I15, R1   | I14 (no DB reach from sessions) | I16 (intake content is data)  |
| T3  | I8, I9                                         | —                                   | I9                | I9, I14                         | I8 (signed webhooks), I9, I15 |
| T4  | I17                                            | I1, I3 (bounded by the session), R1 | I7, I16           | —                               | —                             |
| T5  | I8, I12                                        | I5 (owner-only Bypass), I12         | I7, I12           | I12                             | I12                           |

## 6. Security invariants

I1–I6 restate the roadmap's anti-goals. "Control-plane spec" means Outpost's
`docs/superpowers/specs/2026-11-05-control-plane-design.md`. Its §8 threat model is the prior art
for this document, and its §10 lists the invariant suite cited below.

- **I1 Fail closed.** A gate error, timeout, unreachable decider, unparseable call, unknown tool or
  unrecognised hook answer denies the call. A runtime that can't show every call of a kind reaches
  the gate gets no grant that needs that kind. (Anti-goal; control-plane §10 (viii); T2.13.)
- **I2 Exactly as approved.** An approved external write runs only with the exact command text or
  arguments and file bytes the approver saw, at most once per approval. A failed call may be retried
  identically; an interrupted one runs again only after an already-done check. The approver sees
  everything that will be sent. (Anti-goal; control-plane §10 (ix); T2.4, T2.9, T2.10.)
- **I3 Declared scope.** An action-bound session does only what its action declares, plus work in
  its own checkout. It never falls back to user-wide or global grants, and its grants never widen
  mid-run without an authenticated user decision (I6). Work started by a standing policy (a
  schedule, source intake) runs with that policy's declared grants, never more. (Anti-goal;
  control-plane §10 (x); T2.6, T2.8.)
- **I4 Escape corpus.** Every T2.n capability is refused, except ACP reads while R2 stands. Job 3.2
  turns this list into failing tests. (Anti-goal.)
- **I5 Bypass is the only exception.** Only the session's owning user, from a client, turns Bypass
  on, for one session. A planner, controller or agent never can. The session shows it plainly, and
  Bypass doesn't outlive the session. Job 1.8 owns the design. (Anti-goal.)
- **I6 No self-escalation.** No agent changes A10, pre-approvals or permission modes. Any change
  that widens a grant needs an authenticated user decision, and a write-shaped rule can't land in an
  ungated grant. (Control-plane §10 (vii); T2.11, T2.14.)
- **I7 Credential confinement.** A credential reaches a session only if the session's action
  declares the integration it belongs to. It is used only toward its own service, never logged,
  never stored in plaintext and never sent to a client. (T2.12.)
- **I8 Authenticated access.** Every server route, stream and webhook authenticates its caller,
  except pairing redemption and a health check. Pairing codes are single-use, short-lived,
  rate-limited and stored hashed. A webhook is accepted only with a valid sender signature.
- **I9 Authenticated, encrypted transport.** Clients authenticate the server through a pinned
  long-lived key or private CA, never a pinned leaf and never by network position. Every hop to an
  external service or a remote database verifies TLS, and no grant lets a call turn verification
  off.
- **I10 Revocation.** A device credential can be revoked from another device or the server's CLI.
  Revocation takes effect on the next request and on open streams.
- **I11 Approval provenance.** Every approval, gate decision, Bypass toggle and permission change
  records the acting user and device and is bound to exactly what was decided, so it can't be
  replayed onto another draft. A stolen device credential can't be used off the device, and
  approving or widening a grant needs user presence on the device.
- **I12 Tenant isolation.** Every read and write is scoped by `workspaceId`. A user-scoped
  credential is used only in that user's work. Approving or messaging a session needs a user the
  workspace permits. The acting user is recorded separately from the owner.
- **I13 Local callback channel.** Every endpoint an agent or another host process can reach
  authenticates the calling session and acts only on that session's own step. It is never reachable
  off-host. Identifiers that reach a path or argv are validated against strict patterns. (T2.5,
  T2.14.)
- **I14 Data at rest.** Credentials in the database are encrypted with a key held outside the
  database. Sessions hold no database credential, and the database files are outside every action's
  file scope. A remote database connection is authenticated and encrypted.
- **I15 Idempotent external writes.** A retry or restart never repeats an external write, from the
  outbox or under a pin. Each has an idempotency key and, where the service allows a read-back, an
  already-done check; otherwise it runs at most once. (Control-plane §7.)
- **I16 Untrusted content is data.** Content from repos, tickets, comments, the web, MCP output and
  webhook bodies never changes grants or control flow except through typed tool calls the gate
  decides. Clients render it as inert text.
- **I17 Supply chain.** A dependency change reaches `main` only through a reviewed PR that passes
  the CI gate (ADR 0001, 0002). Release artifacts (Homebrew bottle, notarized Mac app, store builds)
  are verifiable against published checksums or signatures.

## 7. Known residual risks

Outpost documents these gaps and doesn't close them. Job 1.8 must close each one or accept it in its
spec.

- **R1 Build and test execution.** A session granted build or test commands runs code it just wrote
  in its checkout. That code can do anything the session's OS user can, including use a credential
  in its environment to make an external write that never reaches the gate, so I2 holds only for
  writes shaped as a tool call the gate can inspect. (Outpost `deferred.md`.)
- **R2 Ungated reads on ACP runtimes.** ACP agents read without asking, so I3's read scope isn't
  enforced there, and external writes are refused for them. (Outpost `permissions.md`.)

## 8. Out of scope

- A compromised server host, a malicious root user, or malware running as the server's OS user.
  Another non-root OS user on the same host is in scope through I13.
- A malicious or compromised agent runtime binary or model provider. Majula trusts the runtime the
  user installed to report its calls; I1 covers a failing hook, not a lying runtime.
- A compromised account at GitHub, a job source or another external service, and a compromised
  database host.
- Denial of service, beyond failing closed.
- A user who approves a harmful write they could read, and anything done in a Bypass session.
- Physical and side-channel attacks on the server machine.
- Social engineering of the user.
