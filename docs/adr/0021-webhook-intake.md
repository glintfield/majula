# 0021. Webhook intake

- Status: Accepted
- Date: 2026-11-27

## Context

Job 1.9 designs the job-source interface and job 5.1 builds intake, including webhooks, so how a
webhook reaches the server and proves its sender has to be fixed first. The constraints:

- **I8.** A webhook is accepted only with a valid sender signature.
- **I16.** Webhook bodies are untrusted content. They never change grants or control flow except
  through typed decisions.
- **The roadmap's "Sources default to polling".** Webhooks are an upgrade for a server that is
  publicly reachable. A laptop behind NAT can't receive them.
- **[ADR 0007](0007-command-event-outbox.md).** Webhook intake is signature-checked before it
  becomes an observation command.
- **[ADR 0018](0018-server-identity-trust.md).** Webhooks arrive on their own listener, the only
  one that serves a publicly trusted certificate.

Outpost has no inbound webhooks. It polls Linear and posts outbound to Slack, so this design
starts fresh.

## Decision

- **Webhooks arrive only on the webhook listener**, which is off by default.
- **Every delivery is verified against its intake's secret over the raw bytes**, then checked for
  freshness and deduplicated, before anything parses it.
- **A verified delivery is a hint by default.** The server re-reads what it names from the source.

### Listener

- The webhook listener (ADR 0018) is off until dc turns it on, once the server is publicly
  reachable through ACME on a name dc owns or through Tailscale Funnel.
- It serves only `POST /webhooks/<intakeId>` and the health check. Client RPCs are never served
  there, and webhooks are never accepted on the client API listener.

### Intakes

- An **intake** is a server record for one source subscription, with the TypeID prefix `whk`.
  Like every ID it is a name, not a secret ([ADR 0006](0006-ids.md)).
- It holds the source kind, the verification parameters for that source's scheme, and a signing
  secret. The secret is A5, encrypted at rest (I14).
- Majula generates the secret where the source accepts one it's given. Otherwise dc pastes in the
  secret the source issued.

### Verification

The listener handles each request in this order and stops at the first failure:

1. A rate limit, keyed by address and by intake so a proxy or Funnel's single address doesn't
   make it global. Past it, `429`. Job 5.1 sets the numbers.
2. A server-wide size ceiling, from the declared length, before anything else is read.
3. Look up the intake from the path.
4. Read the raw bytes, up to that source's body cap.
5. Verify the sender's signature over those bytes with the source's scheme, comparing in constant
   time.
6. Where the source signs a timestamp, check it is within that source's window.
7. Drop a delivery whose source delivery ID it has already accepted.
8. Only then parse the body, and record the delivery as an observation command (ADR 0007).

- An unknown intake, a bad signature, a stale timestamp and an oversized body all get the same
  `401` with no body, so a refusal doesn't say which check failed.
- A duplicate gets `200` and is dropped.
- **Every webhook needs a valid signature.** A source whose webhooks can't be signed is read by
  polling only.
- **Nothing is trusted by network position.** A source's published IP ranges are never
  authentication; a source's design may add them as a filter against noise.

### A delivery is a hint

- By default the server treats a verified delivery as news that something changed, and re-reads
  that object through its own source client, which verifies TLS, before acting.
- A source's design (jobs 1.9 and 5.2–5.6) may act on body fields directly where the source's API
  can't read them back, and says so in its spec. Such a source must also check a signed timestamp
  or a monotonic version and drop a delivery older than what it already applied, and keep
  delivery IDs at least as long as its replay window, so a replayed or reordered delivery can't
  roll state back.
- Either way the body is untrusted data (I16).

### Secret rotation

- Rotating an intake's secret keeps the old secret valid beside the new one until dc confirms the
  source signs with the new one.

## Alternatives

- **Webhooks on the client API listener.** It would put a public surface on the port that
  carries device traffic, and make that port's exposure depend on whether webhooks are on.
- **A secret URL path as authentication.** Paths leak into logs and proxies, and I8 requires the
  sender's signature.
- **Trusting the signed body as the object's state.** A replayed or out-of-order delivery could
  roll state back, where re-reading the object gives the current state every time.
- **A hosted relay that receives webhooks for servers that aren't reachable.** It would be a
  hosted service, which v1 doesn't have.

## Consequences

- Job 1.9's intake contract builds on this. Job 5.1 builds the intake routes, intake records, the
  verifiers, delivery-ID storage and per-source caps. Job 2.7 builds the listener and its
  certificates.
- Each of jobs 5.2–5.6 names its source's signature scheme, timestamp window, delivery-ID header
  and body cap, or declares the source polling-only.
- Accepting an unsigned webhook or serving webhooks on the client API listener needs an ADR that
  supersedes this one.

## Security

This touches T3 × B5 and T2 × B5.

- **I8, I9 (T3 × B5):** a delivery is accepted only with a valid signature over its raw bytes,
  within its source's time window, over a listener whose certificate the source verifies.
- **I16 (T2 × B5):** the body is data. By default the server acts on what it re-reads, not on what
  the body claims.
- **I15:** deduplicating by delivery ID, and re-reading the object, make a replayed delivery
  harmless.
- **I14:** intake secrets are encrypted at rest.

R1 and R2 stand. The threat model is unchanged by this ADR.
