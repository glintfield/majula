# 0018. Server identity and TLS trust

- Status: Accepted
- Date: 2026-11-27

## Context

Job 2.7 builds the server's TLS, and jobs 3.8 and 3.9 build the clients' trust verification, so
how a client knows it reached its own server has to be fixed first. The constraints:

- **I9.** Clients authenticate the server through a pinned long-lived key or private CA, never a
  pinned leaf and never by network position.
- **[ADR 0003](0003-api-schema.md).** A client's only anchor is a long-lived private CA or server
  key, leaves are short-lived and rotate with no client change, clients keep the platform's full
  evaluation of chain, expiry, hostname and EKU, and the private CA is preferred because it's the
  variant the spike tested. It left how the Apple client takes a trust root to jobs 1.7 and 3.8.
- **The roadmap.** Setup must not need a tailnet or hand-minted certificates. LAN IPs change, and
  Apple rejects leaves valid for more than 825 days. Each client profile has its own trust root.

The [API spike](../spikes/1.6-api-spike.md) anchored both clients on a private CA that signed
one-day leaves, and rotated the leaf between calls. It left three gaps to this job: a raw pinned
server key is untested, no test holds a connection across a rotation, and connect-swift's
`URLSessionHTTPClient` can't take a trust root, so the spike carried its own ~260-line transport.

Outpost is requirements, not a template. Its clients reach it over HTTPS on the tailnet IP with a
`tailscale cert` leaf, and are authenticated by tailnet membership, which is network position. Its
`src/tailscale.ts` records what Tailscale's CLI does to a server: it can block indefinitely, the
App Store build is sandboxed and rejects an absolute `--cert-file`, and under launchd it needs
`TAILSCALE_BE_CLI=1`. Its push VAPID key is never rotated because rotating it invalidates every
subscribed device, which is the same constraint a client anchor puts on the key behind it.

This ADR doesn't decide pairing ([ADR 0019](0019-pairing-profiles.md)), device credentials
([ADR 0020](0020-device-credentials.md)) or webhook intake ([ADR 0021](0021-webhook-intake.md)).

## Decision

- **Each server has one long-lived private CA**, and its identity is the hash of the CA's key.
- **Leaves last 7 days** and rotate with no client change.
- **The client API listener presents only private-CA leaves**, on every address. Publicly trusted
  certificates are served only on the separate webhook listener.
- **A client anchors on its profile's CA alone**, with full platform evaluation.
- **The Apple client keeps its own URLSession transport.**

### Server CA and identity

- On first start the server mints its **server CA**: ECDSA P-256 with SHA-256,
  `basicConstraints CA:true, pathLen:0`, valid 20 years.
- The CA's private key is A7. It is a row in the domain database, encrypted under I14's at-rest
  key from job 2.4's secret providers, and never leaves the server except encrypted inside a
  backup.
- A backup restored with that key keeps the server's identity, so paired apps keep their trust
  anchor. Their devices are suspended until dc confirms them
  ([ADR 0020](0020-device-credentials.md)).
- The CA is never installed in an operating system's trust store. A client anchors on it only
  inside that one profile's transport.
- **The server identity** is the SHA-256 of the CA certificate's DER SubjectPublicKeyInfo. Every
  security decision uses all 32 bytes.
- A **short fingerprint**, the first 80 bits in grouped base32, is shown by the CLI and the apps
  so dc can compare them. Nothing decides on it.
- As [ADR 0006](0006-ids.md) says, the identity isn't a record ID: no domain record carries it as
  a column or a reference.

### Leaves and rotation

- A leaf is ECDSA P-256 with a fresh key, the `serverAuth` EKU and a SHA-256 signature. It is
  valid 7 days, with `notBefore` backdated 1 hour for clock skew.
- Its SANs are `localhost`, `127.0.0.1`, `::1`, the host's current LAN addresses, the mDNS name
  `<host>.local`, the Tailscale IP and MagicDNS name while Tailscale is up, and any extra names dc
  configures, such as a dynamic-DNS name.
- The server sends the chain `[leaf, server CA]`.
- It issues a new leaf when less than half the current one's validity remains, when its address
  set changes (checked every 60 s), and at start when the leaf is missing or expired.
- Leaves are connection material, not domain state. They aren't backed up and aren't restored.
- **An open connection keeps the leaf it handshook with**, even past that leaf's expiry, because
  TLS decides trust at the handshake. New handshakes get the current leaf. This is untested; job
  2.7 adds a test that holds an HTTP/2 connection across a rotation and asserts that calls on it
  keep working and that a new connection sees the new leaf.

### Listeners and TLS modes

- **The client API listener** carries Connect on `node:http2`. It presents private-CA leaves on
  every interface and every endpoint type, Tailscale included. Port and bind address are job 2.4's
  configuration; by default it binds every interface.
- **The webhook listener** is a separate listener, off by default, that serves only webhook
  intake and a health check ([ADR 0021](0021-webhook-intake.md)). It is the only place a publicly
  trusted certificate is served: from ACME for a name dc owns, or from `tailscale cert` for
  Tailscale Funnel.
- So the TLS modes job 2.7 builds split this way: the local CA with rotating leaves serves the
  client API, and Tailscale certificates and ACME serve only the webhook listener. Neither is
  ever a client's anchor.
- **Nothing is trusted by network position.** Being on the LAN or the tailnet grants nothing;
  every endpoint is checked against the same anchor ([ADR 0019](0019-pairing-profiles.md)).

### Client verification

- A profile's server CA is its transport's only anchor: on Apple,
  `SecTrustSetAnchorCertificates` with `SecTrustSetAnchorCertificatesOnly(true)`; on Android, an
  OkHttp `HandshakeCertificates` with no platform roots. The one moment a client handles a chain
  before it holds the anchor is ADR 0019's pairing bootstrap, which only reads it.
- The platform's full evaluation of chain, expiry, hostname or IP SAN and EKU still runs, as ADR
  0003 requires.
- No SPKI pin is layered on top. The anchor is the pinned key, so a pin of it adds nothing.
- A trust rejection is detected by the client's own signal, never from a Connect code
  ([ADR 0011](0011-api-conventions.md)).

### Apple transport

- The Apple client keeps a URLSession `HTTPClientInterface` of its own, starting from the spike's
  `AnchoredHTTPClient`, which job 3.8 hardens against the spike's listed gaps.
- Job 3.8 also proposes upstream that connect-swift's URLSession client forward the session's
  authentication challenge, and the app moves to that hook once it ships.

### Identity reset

- **The server's identity never changes, except through `majula identity reset`** on the host. It
  mints a new server CA and revokes every device but the host device (ADR 0020). Every app must
  pair again, and an old profile shows a trust failure until dc removes it.
- There is no in-band CA rollover in v1.

## Alternatives

- **A raw pinned server key with self-signed leaves.** Untested on both clients, and each would
  need a verifier of its own: on Kotlin a pin only filters chains platform trust already accepted,
  and on Swift it means walking the chain by hand. Not chosen. A superseding ADR that adopts it
  must spike it on both clients first.
- **Public PKI only, through ACME or Tailscale certificates.** It needs a public DNS name or a
  tailnet, which setup mustn't require, and it proves control of a name, not possession of this
  server's key.
- **Tailnet membership, Outpost's choice.** That is trust by network position, which I9 rules out.
- **One long-lived leaf.** Apple refuses leaves valid for more than 825 days, and the leaf's IP
  SANs go stale when LAN addresses change.
- **A leaf per name, chosen by SNI.** It would stop one leaf from listing every address, at the
  cost of more issuance and selection logic. The disclosure is accepted below.
- **NIO for the Apple transport.** It leaves URLSession, so it loses the system's network-path
  handling, VPN and cellular behaviour, and URLSession's handling of the local-network privacy
  prompt, and the spike didn't test it.

## Consequences

- Job 2.7 builds the server CA, the leaf issuer, address watching and rotation, the
  rotation-across-connection test, and the webhook listener with its ACME and Funnel certificates.
  Its Tailscale calls time out and fall through to starting without Tailscale, and handle the App
  Store CLI's sandbox and launchd's `TAILSCALE_BE_CLI`, as Outpost learned.
- Job 2.4 provides the at-rest key that encrypts the CA key's database row. Under
  [ADR 0012](0012-node-interface.md)'s lint rule, the listeners, the leaves and the Tailscale and
  ACME clients live in `host/`, and the database row is `storage/`'s.
- Job 3.8 owns the Apple transport and the upstream proposal. Jobs 3.8 and 3.9 store each
  profile's server CA with its keys.
- Changing the anchor model, adding CA rollover or serving publicly trusted certificates on the
  client API needs an ADR that supersedes this one.

## Security

This touches T3 × B1, T6 × B1 and T3 × B5.

- **I9 (T3 × B1):** impersonating the server needs its CA key. Clients anchor on that CA alone,
  with full evaluation, and never on network position.
- **I9, I18 (T6 × B1):** another server dc's app is paired with can mint a leaf for this server's
  address from its own CA, but no other profile anchors on that CA.
- **I9 (T3 × B5):** ACME and Tailscale traffic verify TLS like every other external call.
- **I14:** the CA key is encrypted at rest under a key held outside the database.
- **Disclosure:** anyone who can open a connection reads the leaf's SANs, which list the host's
  LAN and tailnet addresses and hostname, and the CA's public key, before authenticating. Neither
  is a credential.

R1 and R2 stand. The threat model gains B6, T6 and I18 with ADRs 0019 and 0020.
