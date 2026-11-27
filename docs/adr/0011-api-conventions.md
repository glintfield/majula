# 0011. API conventions

- Status: Accepted
- Date: 2026-11-27

## Context

Job 2.3 adds the first schema to `proto/`, and every later job adds RPCs, so the conventions they
share have to be fixed first. Earlier ADRs left them here:
[ADR 0003](0003-api-schema.md) left versioning, errors, pagination and `buf breaking` in CI,
[ADR 0008](0008-storage-shape.md) the page token on the wire, and
[ADR 0010](0010-subscriptions-cursors.md) page tokens for history and every error code beyond the
ones it names. The constraints:

- **ADR 0003.** Protobuf + Connect, unary and server-streaming calls only, buf v2, and generated
  code committed in all three repos.
- **[ADR 0007](0007-command-event-outbox.md).** A command's receipt is its unary response, with
  `status` `accepted` or `rejected` and a typed rejection code: `stale`, `forbidden`, `invalid`,
  `conflict` or a domain code. A reused command ID with a different digest, a command that can't
  commit, a failed authentication, a revoked device and missing presence get an error with no
  receipt. Retrying with the same `commandId` is always safe.
- **ADRs 0009 and 0010.** A read whose items are gone returns `expired`. A cursor that can't
  resume gets a reset, and only a malformed one is an error. ADR 0009 leaves the length cap on a
  derived fact's one-line summary here.
- **Multiple servers per client.** An app keeps one profile per server, and an offline or
  outdated server affects only its own profile.
- **Independent upgrades.** The server upgrades through Homebrew, and the apps through the stores
  and a notarized Mac build, so any app version can meet any server version.

The [API spike](../spikes/1.6-api-spike.md) found that a trust rejection reaches the client as
`unknown` on Kotlin and, by its reading of the transport, `canceled` on Swift, so no code tells it
apart from a user cancel or an I/O error. Its Swift transport, `AnchoredHTTPClient`, drops the
error body of a non-200 stream response.

This ADR doesn't decide the schema itself or field-type conventions (job 2.3), credential refresh
and presence proofs (jobs 1.7 and 2.6), page-size numbers (the performance budgets), or the branch
ruleset.

## Decision

- **One package per service area, `majula.<svc>.v1`,** changed only additively within a version.
- **A refused command is a receipt, and a Connect error means there is no receipt.** The server
  sends only the Connect codes below, with typed details.
- **Unary history lists page with an opaque page token** over ADR 0008's keyset queries.
- **One integer API level** travels in a header. The server refuses clients below its minimum,
  and clients use only what the server's level offers.
- **`buf breaking` gates every PR** once job 2.3 adds the first schema.
- **A derived fact's summary is one line of at most 120 code points.**

### Packages and versioning

- Each service area is a package `majula.<svc>.v1` in `proto/majula/<svc>/v1/`, such as
  `majula.jobs.v1`. Shared messages, such as error details and the API level, are in
  `majula.common.v1`. Services are named `<Name>Service`. `buf lint` with the `STANDARD` rules
  enforces the version suffix and the directory.
- **Within a `vN` package, changes are additive.** Nothing is deleted, renamed, renumbered or
  retyped. What's no longer used is marked `deprecated` and stays.
- A change that can't be made additively goes in a new `majula.<svc>.v(N+1)`, served beside the
  old package. The old package is deleted only once the server's minimum API level is above
  every level that used it. The PR that deletes it adds its directory to `buf.yaml`'s
  `breaking.ignore`, so the one sanctioned deletion shows in review.
- The apps use the Connect protocol with the binary Protobuf codec. The server also accepts
  Connect JSON, for debugging with `buf curl`.

### Errors

- **A refused command is a receipt, never a Connect error.** A command that decide refuses commits
  a `rejected` receipt (ADR 0007), returned in a successful response. The wire carries ADR 0007's
  rejection codes as an enum in `majula.common.v1`, with typed details: `Stale` carries the
  current version, and each domain code is a detail message the job that adds it defines.
- **A Connect error means there is no receipt.** It covers what ADR 0007 refuses before or outside
  the bus, malformed requests and reads. The server sends these codes, and `deadline_exceeded`
  below, and a client treats any other code from the server as `internal`:

| Code                  | Sent when                                                   | Client does                                            |
| --------------------- | ----------------------------------------------------------- | ------------------------------------------------------ |
| `unauthenticated`     | The credential is missing, invalid, expired or revoked      | Refreshes it once, then reconnects or stops (ADR 0010) |
| `permission_denied`   | The device's scope refuses the call, or presence is missing | With `PresenceRequired`, asks for presence and retries |
| `invalid_argument`    | A malformed request, cursor, page token or level header     | Doesn't retry the request as sent                      |
| `already_exists`      | A command ID is reused with a different payload             | Treats it as a client bug                              |
| `not_found`           | A point read names an ID that doesn't exist                 | Drops the entity from its cache                        |
| `failed_precondition` | The client's API level is below the server's minimum        | Asks dc to update the app, on that profile only        |
| `resource_exhausted`  | A rate or concurrency limit refuses the call                | Retries after `RetryAfter`                             |
| `unavailable`         | The server is starting up or shutting down                  | Retries with backoff                                   |
| `internal`            | Anything else, including a command that can't commit        | Shows an error, and may offer a retry                  |
| `unimplemented`       | Connect's answer to an unknown procedure                    | Treats the feature as missing on that profile          |

- On a stream, `permission_denied` and `invalid_argument` stop that subscription only, as ADR 0010
  says. On a unary call, `permission_denied` without `PresenceRequired` is shown and not retried.
- A retry of a command after a Connect error reuses its `commandId`. After a `rejected` receipt,
  the client's next attempt is a new command with a new ID (ADR 0007).
- A refused page token carries `InvalidField { field: "page_token" }`, and the client restarts
  that list from its first page.
- `deadline_exceeded` comes from the client's own timeout, or from the server when a call outlives
  the deadline the client sent. The client treats it like `unavailable`. `canceled` arises only on
  the client. The server doesn't send `out_of_range`, `aborted` or `data_loss`.
- **Expected absence is a result, not an error.** ADR 0009's `expired`, ADR 0010's resets and
  `removed` entries, and an empty page are results. `not_found` is only for a point read.
- **Details are typed messages** in `majula.common.v1`. This ADR adds
  `UpgradeRequired { min_api_level }`, `PresenceRequired`, `CommandIdReused { command_id }`,
  `InvalidField { field, reason }` and `RetryAfter { delay_ms }`; later jobs add their own.
  Clients branch on the code and on detail types they know, ignore detail types they don't, and
  never parse `message`.
- **`message` is diagnostic English for logs.** It never carries a credential, and a client shows
  it only as inert text.
- **A trust rejection isn't an API error.** It happens before the server answers. Clients detect
  it only through their own trust signal (ADR 0003), never from a Connect code, and never retry
  it over another trust path.

### Pagination

- A list request has `int32 page_size` and `string page_token`. Its response has the items and
  `string next_page_token`, which is empty after the last page.
- `page_size` 0 asks for the server's default, and a larger size than the cap is clamped, not
  refused. The performance budgets set both.
- **A page token is opaque to clients.** The server encodes the last row's keyset position, a
  format version and a digest of the request's filters and direction. It parses the token
  strictly, and refuses one that doesn't parse, has an unknown version or doesn't match the
  request with `invalid_argument`.
- Tokens aren't signed. Like an ADR 0010 cursor, a forged token only moves where an authenticated
  caller's list starts, and grants nothing.
- Tokens don't expire and survive restarts, because they name a key, not a position in a feed. A
  deleted row at that key doesn't affect a keyset read after it.
- **A list's order key never changes once its row exists**, so pages never repeat or skip a row.
  It is a seq, an ID or a tuple ending in an ID, such as `(finishedAt, id)`, and a list keyed on a
  finish time holds only entities whose finish is final. A view whose order moves with work is a
  subscription scope (ADR 0010), not a paged list.
- There are no totals, page numbers or offsets (ADR 0008). Items are the same entity messages the
  streams carry.
- A list that reads backwards, such as ADR 0010's older transcript items, says so in its RPC, and
  its token carries the direction.

### API level and compatibility

- **One integer API level covers the whole schema.** It is the highest value of
  `enum ApiLevel` in `majula.common.v1`, whose values are appended: `API_LEVEL_UNSPECIFIED = 0`,
  `API_LEVEL_1 = 1` and so on.
- **A PR that adds an RPC, message, field or enum value, other than an `ApiLevel` value, appends
  the next `ApiLevel` value.** A comment or a `deprecated` option doesn't. The new element's
  comment names its level.
- **Both sides send their level.** Every request but the health check carries `majula-api-level`
  with the level the app was generated at. Every response to an authenticated call, errors
  included, carries the server's. A client keeps the server's level per profile and updates it
  whenever a response shows a new one, as it does after an upgrade restarts the server.
- **The server's minimum client level** is a constant in server code. It rises only to retire a
  `vN` package, for a security fix old clients can't follow, or for a field whose absence would
  weaken a check (below). A call below it gets `failed_precondition` with `UpgradeRequired`. The
  server never refuses a client for being newer. A change to how clients authenticate can't reach
  old apps as `UpgradeRequired`, because the check runs after authentication, so it gets a
  deprecation window instead of a raised minimum.
- **The check runs after authentication,** so an unauthenticated caller learns nothing, and a
  response that fails authentication carries no level. Pairing redemption checks the level first,
  so a too-old app never spends a single-use code. Its responses carry no level header, and its
  `UpgradeRequired` names only the minimum level. The health check takes no header, makes no check
  and returns no level. Every other call without a valid header gets `invalid_argument`.
- **Each app has a minimum server level.** Below it, the app asks dc to upgrade that server, on
  that profile only.
- **Clients gate features on the server's level.** A client uses only the RPCs and fields its last
  known server level offers. After a server is downgraded or restored to an older install, the
  first call can still exceed it, and gets `unimplemented` or has a field dropped; the rule below
  keeps a dropped field from weakening a check.
- **A field whose absence would weaken a check never joins an existing request.** It comes with a
  new RPC or a raised minimum level. The server treats such a field as possibly absent, and a check
  never passes on its absence.
- **Clients handle what they don't know.** An unknown enum value or entity kind renders as a prompt
  to update the app and enables no action, and unknown fields are ignored. The server doesn't
  tailor responses to a client's level unless the design doc of the RPC says so.
- Any other caller of the API, such as the CLI if it uses Connect, sends its level like an app.

### Summaries

- A derived fact's summary, such as a subagent's one-line summary in ADR 0009, is plain text with
  no line break and at most 120 Unicode code points. When it records the fact, the server replaces
  line breaks with spaces and truncates longer text on a grapheme-cluster boundary, ending it with
  `…`, which counts toward the 120.

### `buf breaking` in CI

- **The rule.** Every pull request runs `buf breaking` on `proto/` against its base on `main`,
  with the `FILE` category, buf's default. The same job runs `buf lint` with `STANDARD` and checks
  that a schema addition appended an `ApiLevel` value. A PR fails if any of them fails.
- **When it starts.** Job 2.3, which adds `proto/buf.yaml` and the first schema, adds a CI job
  named `buf` to `.github/workflows/ci.yml`. It installs buf from npm as `@bufbuild/buf`, pinned
  by the lockfile, runs it through a pnpm script, and adds that script to CLAUDE.md's gate table.
  The breaking step and the level check compare against the base, and are skipped only when the
  base has no schema, which happens only in 2.3's own PR. On a push to `main`, the job runs
  `buf lint`. The breaking check still covers every schema change, because branch protection
  takes changes into `main` only through pull requests.
- **Not now.** `proto/` has no schema, so a breaking check would have nothing to compare against.
- **Job names.** No existing CI job is renamed. Once `buf` has run on `main`, dc adds it to the
  branch ruleset's required checks, as a separate admin change. Requiring it earlier would block
  every PR on a check that never reports.

## Alternatives

- **One package for the whole API, or unversioned packages.** One break would force every service
  to a new version, or leave no room for one.
- **`v1alpha1` packages with buf's `ignore_unstable_packages` until the first store release.** The
  gate would sit idle while dc's development builds already run against newer servers.
- **Refused commands as Connect errors.** The client loses the receipt and can't tell a committed
  refusal from a call that failed, which breaks ADR 0007's retry rule.
- **`google.rpc.ErrorInfo` with string reasons.** Clients would branch on free text, where typed
  detail messages are checked by the compiler.
- **Offsets or page numbers.** ADR 0008 rules them out.
- **Cursors held on the server.** Per-client state outside the database, which ADR 0007 rules out
  for domain state, and lost on restart.
- **Signed page tokens.** Key management to protect a token that grants nothing.
- **Comparing app versions.** Store and build numbers differ by platform, and the server can't map
  them to what an app supports.
- **Capability flags.** An open-ended registry, where the server's releases are linear and one
  number orders them.
- **Detecting features by `unimplemented`.** It misses a field an older server silently drops.
- **A `GetServerInfo` RPC.** A round trip on every reconnect, stale after an upgrade, where a header
  rides every call.
- **The `WIRE` and `WIRE_JSON` categories.** They allow renames that break the generated code in
  all three repos.
- **The `PACKAGE` category.** It allows moving a type between files, which changes generated import
  paths.
- **Adding the CI job now.** It has no schema to compare, and needs a ruleset change for a check
  that proves nothing.

## Consequences

- Job 2.3 adds `proto/buf.yaml`, `majula.common.v1` with `ApiLevel` and the detail messages above,
  the `buf` CI job and its pnpm script, the CLAUDE.md row, a server interceptor that reads and
  sends `majula-api-level` and enforces the minimum, and the page-token codec over job 2.1's
  keyset reads. Its interceptor maps any thrown error that isn't a Connect error to `internal`.
  It also updates CLAUDE.md's "Run all five" to count the new job.
- This moves ADR 0003's consequence that job 1.5 adds `buf breaking` to CI: job 1.5 sets the rule
  here, and job 2.3 adds the job.
- Job 3.1's session adapter truncates summaries to the cap when it records derived facts.
- Job 1.7 designs presence proofs and credential refresh around `PresenceRequired` and
  `unauthenticated`, and job 2.6 builds them.
- Jobs 3.8 and 3.9 keep the server's level per profile, gate features on it, render unknown
  values inertly and act on each code as the table says. Job 3.8 makes the Apple transport keep
  the error body of a non-200 stream response, which carries `UpgradeRequired` and
  `unauthenticated` when a stream is refused at its start.
- The performance budgets set the default and maximum page size, and the concurrency limits when
  `resource_exhausted` is sent.
- dc adds `buf` to the ruleset's required checks after job 2.3 lands.
- Deleting from a `vN` package other than by retiring the whole package, versioning by app or
  platform version, sending a refused command as a Connect error, or signing or expiring page
  tokens needs an ADR that supersedes this one.

## Security

This touches T1 × B1, T2 × B1, T3 × B1 and T4 × B1.

- **I8 (T1 × B1, T3 × B1):** the API level adds no unauthenticated surface. The check runs after
  authentication, and only authenticated responses carry the server's level. Pairing redemption
  reveals only the minimum level, and the health check no level at all.
- **I10 (T1 × B1):** a revoked device gets `unauthenticated`, its refresh fails, and the client
  stops, as ADR 0010 says.
- **I1, as a property of the conventions rather than through these cells:** a field whose absence
  would weaken a check never joins an existing request, and an unknown value enables no action.
- **I9 (T3 × B1):** clients never infer a trust rejection from a code, and never retry one over
  another trust path.
- **I11 (T1 × B1):** a refused command keeps its receipt and actor, and missing presence is a typed
  refusal the client answers with presence, never a way around it.
- **I16 (T2 × B1):** `message` and details are data, rendered as inert text and never parsed.
- **I7, the same way:** no error carries a credential.
- **I17 (T4 × B1):** buf is pinned by the lockfile, and once the `buf` job is on, a schema change
  reaches `main` only through a pull request that passes it.
- **I15, the same way:** a retry after a Connect error reuses its `commandId`, so it can't repeat
  a write.

R1 and R2 stand. The threat model is unchanged.
