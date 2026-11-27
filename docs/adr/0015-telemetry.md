# 0015. Telemetry

- Status: Accepted
- Date: 2026-11-27

## Context

The 1.5 bullet asks for telemetry that is off unless dc opts in. The roadmap's constraints:

- **Non-goals.** v1 has no hosted Majula service run by dc, and no push relay.
- **Anti-goals.** No server serves more than one person, and no client leaks between servers: one
  server's data, credentials or device identity never reaches another.
- **Open source.** All repos are public, so anything a build sends is readable in its source.
- **Agent terms** (`docs/policy/agent-terms.md`, Q4). Plan usage comes only from data the runtimes
  emit in sessions Majula runs, and whether surfacing it to a third party is allowed is unclear.

Outpost sends no telemetry.

This ADR doesn't decide a telemetry endpoint, its schema in code, or the settings screen. A later
job that adds a sender does, under the rules here.

## Decision

- **Telemetry is off on every server until dc turns it on for that server.**
- **v1 ships no sender.** This ADR is the contract a later sender meets.
- **An opt-in sends only a closed, typed schema of counts, versions and codes,** never content,
  credentials, identifiers or free text.
- **The apps send no telemetry.**

### What counts as telemetry

- **Telemetry** is data about Majula's own operation, sent off the host for Majula's maintainers
  rather than to deliver a feature dc uses.
- Calls that deliver a feature aren't telemetry: GitHub, job sources, MCP servers, the runtimes'
  model traffic, ACME and Tailscale (job 2.7), and update checks against GitHub Releases (job 7.1).
  Their own designs govern them.

### Off by default

- Telemetry is off on every install. dc turns it on per server, by a `device` command or by
  `majula config` on the host. It is never shared across server profiles.
- No session, planner or controller can turn it on, and no action's grants cover it.

### No sender in v1

- v1 has no endpoint to send to, since a hosted Majula service is a non-goal. The job that adds one
  builds the setting, the schema, the local log and the sender, under this ADR.

### What an opt-in may send

The payload is a closed, typed schema. Each string field is an enum or a version string that
matches a pattern. It may carry:

- versions: Majula, Node's major version, the OS family and the CPU architecture;
- which runtime kinds the server detected;
- counts of jobs, steps and sessions by state;
- error codes, as enum values ([ADR 0011](0011-api-conventions.md),
  [ADR 0012](0012-node-interface.md));
- the budget figures [ADR 0016](0016-performance-budgets.md) measures.

### What it never sends

- Content: prompts, transcripts, diffs, artifacts, comments, tickets or anything else in A9.
- Credentials (A2–A7).
- Identifiers: record IDs, `projectKey`s, repo, branch or file names, paths, hostnames, IP
  addresses, logins, emails or device IDs.
- Free text of any kind.
- Plan usage or limits, which the agent terms leave unclear.

### Identity, visibility and transport

- A server's telemetry carries a random telemetry ID, distinct from every record ID and from the
  server's identity key (A7). It is regenerated each time telemetry is turned on, and links no
  server to another ([ADR 0006](0006-ids.md)).
- Every report is written to a bounded local log that dc can read before and after it is sent.
- Reports go over HTTPS with verified TLS (I9), to one endpoint fixed in the build, following no
  redirects.

### Apps and diagnostic bundles

- The apps send no telemetry and embed no analytics or crash-reporting SDK. Crash reports the
  platform collects because the OS user enabled them, such as App Store and Play Console reports,
  are outside Majula.
- If job 2.4 adds a diagnostic bundle to `majula doctor`, the bundle keeps to the content rules
  above, is written locally and isn't uploaded by Majula.

### Absolutes and their exceptions

| Rule                                                              | Exceptions                                                          |
| ----------------------------------------------------------------- | ------------------------------------------------------------------- |
| Nothing is sent as telemetry unless dc opted in on that server    | None                                                                |
| Telemetry carries no content, credential, identifier or free text | The server's random telemetry ID                                    |
| Only dc turns telemetry on                                        | None                                                                |
| The apps send no telemetry                                        | Crash reports the platform collects for an OS user who enabled them |

## Alternatives

- **On by default, with an opt-out.** It sends data dc never agreed to, which the 1.5 bullet rules
  out.
- **Free-form events.** No review can show that a payload can't carry a path or a secret.
- **A third-party analytics SDK.** A dependency that sees whatever the process sees (T4).
- **One ID across a client's servers.** It links servers, which the anti-goals forbid.
- **Building a sender now.** It needs an endpoint run by dc, which the roadmap rules out for v1.

## Consequences

- The job that adds a sender builds the setting, the schema with a test that it has no free-text
  field, the local log and the endpoint, and records the destination under B5 in the threat model
  as a call the server makes to an external service.
- Job 2.4's diagnostic bundle, if it adds one, follows the content rules.
- Turning telemetry on by default, sending content or identifiers, or adding an analytics SDK to
  the apps needs an ADR that supersedes this one.

## Security

This touches T2 × B5 and T3 × B5.

- **I16 (T2 × B5):** the schema has no field that could carry content an agent read.
- **I6:** no session, planner or controller turns telemetry on, so an agent can't open it as a
  channel.
- **I9 (T3 × B5):** reports verify TLS to one fixed endpoint and follow no redirects.
- **I7:** no credential is sent.
- **Client separation:** the telemetry ID is random per server, so it links no two profiles.

R1 and R2 stand. The threat model is unchanged.
