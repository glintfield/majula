# 0019. Pairing and server profiles

- Status: Accepted
- Date: 2026-11-27

## Context

Job 2.6 builds pairing on the server, and jobs 3.8 to 3.11 build it, and server profiles, in the
apps. The constraints:

- **The roadmap's "Multiple servers per client".** An app pairs with any number of servers, one
  server profile each. Profiles share nothing: each has its own device key, tokens, trust root,
  cache and settings. Each server has a stable identity in its pairing payload, so pairing the
  same server again updates its profile. Removing a profile revokes its device and wipes its keys
  and cache. Neither server should learn the other exists.
- **The roadmap's job 1.7.** Pairing by QR or code, and a payload with typed endpoints:
  `direct_https`, `tailscale`, and later `relay`. Setup must not need a tailnet.
- **"Inbound content names its target."** Links from other apps go to a server dc picks, never to
  whichever profile is on screen.
- **[ADR 0006](0006-ids.md).** The server mints `deviceId` when pairing completes, and the app
  sends no device identifier before it. Pairing again mints a new `deviceId`, and a revoked one is
  never reused.
- **I8.** Pairing redemption is one of two unauthenticated routes. Pairing codes are single-use,
  short-lived, rate-limited and stored hashed.
- **[ADR 0011](0011-api-conventions.md).** Pairing redemption checks the API level first, so a
  too-old app never spends a code. A client never retries a trust rejection over another trust
  path.

The server identity and the server CA are [ADR 0018](0018-server-identity-trust.md)'s. The device
and presence keys, tokens and revocation are [ADR 0020](0020-device-credentials.md)'s.

## Decision

- **A pairing payload carries the server identity, typed endpoints and a single-use secret**, as a
  `majula://pair` link that a QR encodes. The "code" is the same link as text.
- **The app checks the server identity before it sends the secret.**
- **A payload for a server that's already paired updates that profile.**
- **Each profile is kept apart from the others** in storage, transport and identifiers.

### Pairing payload

- A protobuf message, defined by job 2.6, carried base64url-encoded in the fragment of a
  `majula://pair#…` link. Its fields:
  - a version
  - the server identity, 32 bytes
  - a server name hint, which is untrusted and only displayed
  - up to 8 endpoints, each a type, a host and a port
  - the pairing secret: 128 random bits, prefix-tagged as `mjp_…` so
    [ADR 0014](0014-retention-redaction.md)'s redactor matches it
  - the expiry and the scopes the new device will get, both for display; the server enforces them
- A QR encodes the link. It is about 300 characters, small enough for a QR printed in a terminal.
- **The code is the link as text**, pasted or AirDropped onto a device with no camera, such as a
  Mac. There is no short typed code (see Alternatives).

### Endpoints

- `direct_https`: an IP literal or DNS name, and a port, reached directly.
- `tailscale`: a tailnet IP or MagicDNS name, and a port, used only when the device can reach the
  tailnet.
- `relay`: reserved, not built in v1. A relay must carry TLS end to end to the server, anchored on
  the same server CA, so it can't read or forge traffic. Its design needs an ADR of its own.
- **Every endpoint type uses the same anchor**, the profile's server CA. Being on the tailnet or
  the LAN grants nothing.
- A client ignores an endpoint type it doesn't know. A payload with no endpoint type it knows is
  refused with a prompt to update the app.
- **Selection.** The client tries the last endpoint that worked, then the others, starting each
  250 ms after the last. A network error moves on to the next endpoint.
- **A trust rejection** on an endpoint is shown and marks that endpoint failed. The client may try
  the profile's other endpoints, which are evaluated against the same anchor, so this isn't
  another trust path in ADR 0011's sense. A client never relaxes the anchor or falls back to
  platform trust.
- The server publishes its current endpoints in an authenticated server-info entity that job 2.6
  defines. A client replaces its stored list only from that entity, or from a pairing payload
  whose redemption succeeds.
- Addresses found by Bonjour (job 2.8) are candidates only, and are checked with full trust
  evaluation like any other.

### Minting

- `majula pair` on the host, through ADR 0020's host device, mints a payload and prints its QR and
  link. Job 7.1's `majula setup` uses it.
- An app can mint one with `MintPairing`, which needs `admin` scope and presence (ADR 0020), for
  example to show a QR to a second device.
- Each **pairing record** holds the SHA-256 of its secret, an expiry 10 minutes out, its scopes
  and its minter. Job 2.6's design names its ID prefix.
- At most 5 are outstanding; minting a sixth is refused with `resource_exhausted`. Redemption
  checks the expiry, and a timer row prunes expired records.
- Pairing records are domain state, which commands create and consume
  ([ADR 0007](0007-command-event-outbox.md)).
- **The secret never enters a receipt or a payload.** The server generates it before the command
  and writes only its hash, into the pairing record's state, so the client-signed payload and its
  digest (ADR 0020's presence proof) never include it. The receipt holds the record's ID and
  expiry. The live response carries the secret beside the receipt, unstored, which extends ADR
  0007's rule that the receipt is the unary response. The secret is held in clear only in memory
  while it is minted and displayed. A retry that gets the stored receipt back gets no secret, and
  the caller mints again.

### Redemption

1. **Bootstrap the anchor.** The app opens a TLS handshake that accepts nothing, reads the chain
   the server presents, and keeps the CA certificate whose SubjectPublicKeyInfo hashes to the
   payload's server identity. It aborts that handshake without sending anything. If no
   certificate matches, it stops and says the server's identity doesn't match. Untested; jobs 3.8
   and 3.9 verify it.
2. The app connects again with that CA as its only anchor and full evaluation (ADR 0018).
3. It generates the profile's device key and, where the device can hold one, its presence key
   (ADR 0020).
4. It calls `RedeemPairing` with the pairing secret, the public keys, the profile's device name,
   its platform, the key protection it reports, and a signature from each key over
   `H("majula-pair-v1" ‖ serverIdentity ‖ SHA-256(secret) ‖ devicePub ‖ presencePub)`, with
   `presencePub` empty when there is no presence key. The server identity in the signed message
   stops a request being replayed to another server.
5. Before the bus, the server checks the API level (ADR 0011), finds the record by the secret's
   hash in constant time, and verifies the signatures. A record that is cancelled or expired
   counts as no match. Any failure gets `unauthenticated` with no detail and no receipt.
6. A `server` command then consumes the pairing record, mints the `deviceId` and records the
   public keys. Its payload carries the pairing record's ID and the public keys, never the secret.
   It cites the pairing record, which names its minter, the way an approval under a pre-approval
   cites the pre-approval's record ([ADR 0006](0006-ids.md)).
   - **This ADR adds redemption to ADR 0007's `server` cases.** The actor can't be a `device`,
     because no `deviceId` exists until this command mints one.
   - Decide refuses a record that is cancelled or expired by the time it runs, with
     `unauthenticated` and no detail.
   - A record that is already consumed gets `conflict`. The one exception is a retry carrying the
     same secret hash and `devicePub` as the redemption that consumed it: decide returns that
     redemption's `deviceId` and scopes again, so a lost response doesn't strand the device.
7. The response carries the `deviceId` and the scopes, and no token. The app then calls
   `Authenticate` (ADR 0020).

- **A pairing secret is single-use.** It creates one device, however often that same
  redemption is retried.
- Without a presence key, the server grants only `read` and `operate`, whatever the payload's
  scopes, and `SetDeviceScopes` can't later grant that device `approve` or `admin` (ADR 0020).
- A failed attempt doesn't consume a record, since 128 bits can't be guessed.
- Redemption is rate-limited before authentication: 10 calls a minute per source address and 30 a
  minute across the server. Past either, `resource_exhausted` with `RetryAfter`.

### Pairing a server that's already paired

- A payload whose server identity matches an existing profile updates that profile and never adds
  a second one. The confirmation says which profile it updates.
- The app generates new keys, and redemption mints a new `deviceId`, as ADR 0006 requires.
- If the app still holds the old device key, its request carries
  `replaces { oldDeviceId, signature }`, a signature by the old device key over the same message.
  The server revokes the old device in the same command. This proof is separate from the secret,
  which is still single-use.
- Otherwise the old device stays listed until dc revokes it, and the app offers to.
- The profile keeps its local name, colour, cache and cursors, which belong to the server rather
  than to a device. Only once `RedeemPairing` succeeds does it replace its keys, token, scopes and
  endpoints, the endpoints from the payload. A link that fails to redeem leaves the profile as it
  was.
- A payload with a different server identity is a different server, even when its name or
  addresses match a profile's.

### Removing a profile

- If the server is reachable, the app first sends `RevokeSelf`, which needs no scope and no
  presence (ADR 0020).
- Then, whatever the result, it deletes the profile's keys, token, server CA, cache database,
  cursors and settings.
- An unreachable server keeps the device listed until it's revoked from another device or the
  CLI. Its key is gone, so it can never authenticate again.

### Isolating profiles in the client

- **Profiles share nothing**, except the app's own UI preferences, such as its theme, and the
  operating system's grants to the app, such as camera and local-network access.
- Each profile has its own Keychain or Keystore items, cache database, settings, and HTTP client
  and connection pool, holding only its own anchor.
- Every call is bound to a profile. The network layer has no global current profile.
- The app sends no install ID, hardware ID or push token to any server, and every key is new per
  profile, so nothing links one profile to another.
- The device name is per profile. It defaults to the platform and model, such as "iPhone", never
  the operating system's device name, and dc can rename it in each profile.
- **A pairing link is inbound content.** The app shows which server it pairs or updates and does
  nothing until dc confirms.

## Alternatives

- **A short typed code with a PAKE**, such as CPace or SPAKE2. The best design for a code typed by
  hand, but no PAKE ships with CryptoKit, Android or Node. A superseding ADR can add one after a
  spike on all three.
- **A short code sent over a first, unverified connection.** An attacker in the middle learns the
  code and pairs itself, or guesses it offline from what it saw.
- **A short code plus a short authentication string compared on both screens.** Sound, but it
  needs a confirmation on the server side as well as the app, for what a pasted link does in one
  step.
- **The server CA certificate in the payload.** About 500 more bytes and a denser QR, when the
  handshake already carries the certificate and the payload's hash pins it.
- **Re-pairing adds a second profile.** The roadmap rules it out.
- **Keeping the `deviceId` on re-pair.** ADR 0006 rules it out.

## Consequences

- Job 2.6 builds pairing records, `MintPairing`, `RedeemPairing` with the replace proof, its rate
  limits, and the server-info entity with the current endpoints.
- Job 2.8 treats Bonjour results as candidate addresses.
- Jobs 3.8 and 3.9 build the bootstrap and profile isolation; their done criterion already covers
  isolation. Jobs 3.10 and 3.11 build QR scanning, the link, the confirmation, re-pairing and
  removal.
- Job 7.1's setup shows the payload.
- The `mjp_` tag sits inside base64url in a link, so ADR 0014's redactor also matches
  `majula://pair#[A-Za-z0-9_-]+`. Job 2.4 adds that pattern with `mjp_` and ADR 0020's `mja_`.
- A typed code, a relay endpoint or reusing a `deviceId` needs an ADR that supersedes this one.

## Security

This touches T3 × B1, T1 × B1, T2 × B1, T2 × B6, T6 × B1 and T6 × B6.

- **I8, I9 (T3 × B1):** the app sends the secret only after the server proves its identity. The
  secret is single-use, expires after 10 minutes, is stored hashed and is rate-limited, and the
  signed redemption names the server, so it can't be replayed elsewhere.
- **I11 (T1 × B1):** minting a payload from an app needs presence, so a stolen phone can't pair a
  new device without its owner.
- **I16 (T2 × B1):** the server name hint is untrusted and rendered as inert text.
- **I16, I18 (T2 × B6):** a pairing link is inbound content. It acts only on the server its
  identity names, and only once dc confirms.
- **I9, I18 (T6 × B1, T6 × B6):** every profile anchors on its own server CA, keys are new per
  profile, and no identifier crosses profiles, so a co-paired server can neither impersonate
  another server nor link the app to it.

R1 and R2 stand. This ADR adds B6, T6 and I18 to the threat model.
