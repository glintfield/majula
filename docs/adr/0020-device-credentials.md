# 0020. Device credentials

- Status: Accepted
- Date: 2026-11-27

## Context

Job 2.6 builds authentication, scopes and revocation, and every later job adds RPCs and commands
that rely on them. The constraints:

- **I8.** Every route, stream and webhook authenticates its caller, except pairing redemption and
  a health check.
- **I10.** A device credential can be revoked from another device or the server's CLI, and
  revocation takes effect on the next request and on open streams.
- **I11.** Approvals record the acting device. A stolen device credential can't be used off the
  device, and approving or widening a grant needs user presence on the device.
- **I14.** Credentials in the database are encrypted with a key held outside it.
- **[ADR 0007](0007-command-event-outbox.md).** A command's actor is set from the authenticated
  caller. A failed authentication or a revoked device is refused before the bus, and presence is
  verified there too.
- **[ADR 0010](0010-subscriptions-cursors.md).** Every stream is bound to the credential that
  opened it. Revoking a device ends its streams, expiry ends them with `unauthenticated`, and a
  scope change that would refuse the opening call ends them with `permission_denied`.
- **[ADR 0011](0011-api-conventions.md).** `unauthenticated`, `permission_denied` with
  `PresenceRequired`, and `resource_exhausted` with `RetryAfter`. A change to how clients
  authenticate gets a deprecation window rather than a raised minimum level.
- **[ADR 0006](0006-ids.md).** The server mints `deviceId` (`dev_…`), never reuses a revoked one,
  and a `deviceId` isn't a key fingerprint.

The [API spike](../spikes/1.6-api-spike.md) checked a static bearer token only when a call
started, so revoking it wouldn't end an open `Watch`. Outpost's `src/permissions/hook-server.ts`
opens every loopback route with one shared secret, compared with `!==`, and returns 404 for an
unknown route before checking it. Outpost's push subscriptions aren't tied to a device and aren't
removed when one goes away.

Pairing is [ADR 0019](0019-pairing-profiles.md)'s, and the server identity
[ADR 0018](0018-server-identity-trust.md)'s.

## Decision

- **Each profile holds a device key and, where the device can hold one, a presence key**, neither
  of which can be exported.
- **The device key buys a 1-hour access token**, held only in memory on both sides.
- **Every call checks the token, the device's current status, the RPC's scope and, for commands
  that need it, a presence proof.** Revocation doesn't wait for a token to expire.
- **The host CLI is a device** reached over a Unix socket.

### Device and presence keys

- **The device key** is P-256, generated on the device for one profile, and can't be exported. It
  signs `Authenticate` and needs no user authentication, and it can be used after the first
  unlock, so the app reconnects in the background.
  - Apple: in the Secure Enclave, `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
  - Android: in StrongBox where the device has one, else the TEE-backed Keystore.
- **The presence key** is P-256, generated the same way, and needs user authentication on every
  use, with no reuse window in v1.
  - Apple: `.userPresence`, `kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly`.
  - Android: `setUserAuthenticationParameters(0, BIOMETRIC_STRONG | DEVICE_CREDENTIAL)`.
  - A device with no passcode or biometric can't create one. It pairs without one, the server
    grants it only `read` and `operate` (ADR 0019), and the app says why.
- **Device keys never leave the device**, with one weaker case: on hardware with no secure element
  or hardware Keystore, such as an Intel Mac without a T2 chip, both keys are software keys kept
  this-device-only and never synced. The app reports which protection it has, and the server
  shows it in the device list without verifying it.
- **Untested.** None of this has run on a device. Jobs 3.8 and 3.9 each open with a spike that
  proves non-exportable keys sign in the background after first unlock, that presence keys prompt
  on every use, how long StrongBox takes for one signature an hour and one per approval, and the
  software fallback. Job 2.6 tests the protocol with software keys in job 2.5's scripted client.

### Access tokens

- **`Authenticate`** takes the `deviceId`, a timestamp, a 16-byte nonce and a device-key signature
  over `H("majula-auth-v1" ‖ serverIdentity ‖ deviceId ‖ timestamp ‖ nonce)`. It authenticates
  its caller by that signature, so it isn't one of I8's exceptions.
- The server accepts it when the device is active, the signature verifies, the timestamp is
  within 5 minutes of the server's clock, and the nonce hasn't been seen within that window.
- It returns an opaque 256-bit **access token**, prefix-tagged as `mja_…` so
  [ADR 0014](0014-retention-redaction.md)'s redactor matches it, valid for 1 hour.
- Failures are `unauthenticated`. A bad signature or unknown device gets no detail. Once the
  signature verifies, a revoked device gets `DeviceRevoked`, a suspended one `DeviceSuspended`,
  and a timestamp outside the window `ClockSkew { server_time }`. These details join
  `majula.common.v1`; job 2.6 defines them.
- **Tokens are connection state**, like ADR 0010's stream registry. The server holds only a map
  from each token's hash to its `deviceId` and expiry, in memory, with the nonce cache. A restart
  drops both, and every client authenticates again in one call.
- An app holds its token only in memory. It authenticates again at 45 minutes or on
  `unauthenticated`, and reopens its streams with the new token before the old one expires,
  because expiry ends a stream (ADR 0010).
- **On every call** the server looks up the token, then the device's current status, which it
  caches and invalidates when a command changes it, then the RPC's scope, then the presence proof
  if the command needs one. Only then does a command reach the bus.
- **Every route authenticates its caller**, except `RedeemPairing`, authenticated by its pairing
  secret (ADR 0019), and the health check, as I8 allows. Webhooks authenticate by their sender's
  signature ([ADR 0021](0021-webhook-intake.md)), and the host socket by its secret and peer uid.

### Scopes

| Scope     | Covers                                                               |
| --------- | -------------------------------------------------------------------- |
| `read`    | Subscriptions and lists                                              |
| `operate` | Commands that decide nothing for dc, such as messaging a session     |
| `approve` | Approving gates and write drafts, changing modes and accepting plans |
| `admin`   | Devices, pairing, permissions, pre-approvals and server settings     |

- Changing a mode includes entering Bypass, and permissions include grants and groups.
- A paired app gets all four unless its pairing payload was minted narrower, as with
  `majula pair --scopes read`.
- Every RPC declares exactly one required scope in a proto option, except four that run before
  or without one: `Authenticate`, `RedeemPairing`, the health check and `RevokeSelf`. Any other
  RPC without a declared scope is refused, so a forgotten declaration fails closed.
- `RevokeSelf` revokes the calling device and needs no scope, so a read-only device can still
  remove itself. `RevokeDevice` revokes another device and needs `admin`.
- `SetDeviceScopes` needs `admin`, and presence for every change but one: a device narrowing its
  own scopes. Widening any device, the caller included, and narrowing another device both need it.
- It refuses `approve` or `admin` for a device with no presence key.
- A stream that a narrowing would now refuse ends with `permission_denied`, as ADR 0010 says.

### Presence

- **Presence is required for exactly these:**
  - `ApproveGate` ([ADR 0004](0004-gate-state-machine.md)), which covers specs, plans, write
    drafts and reply drafts
  - `SetMode(Bypass)` and `AcceptPlan(Bypass)` ([ADR 0005](0005-session-permission-modes.md))
  - commands that widen a grant: adding or widening permission rules and groups, and setting
    pre-approvals. The jobs that add them (1.8, 3.4) name them under this rule
  - `SetDeviceScopes`, except a device narrowing its own scopes
  - `MintPairing`
  - `RevokeDevice`
- Other decisions, such as `AbandonGate`, `SaveEdit` and `SetMode` to a mode other than Bypass,
  need the `approve` scope but no presence, as ADRs 0004 and 0005 say.
- Two cases act without presence on the device. The host device's allow-list (below) stands in
  OS-user access to the server for presence. A `server` approval under a pre-approval cites the
  pre-approval's record (ADR 0006, ADR 0007), which was set with presence.
- **The proof** is a presence-key signature over
  `H("majula-presence-v1" ‖ serverIdentity ‖ deviceId ‖ commandId ‖ kind ‖ payloadDigest)`, using
  ADR 0007's payload digest, carried in the command envelope.
- The server verifies it before the bus. A missing or invalid proof gets `permission_denied` with
  `PresenceRequired`.
- The proof names the command ID and the payload's digest, and a gate's payload carries its
  revision, so it can't be replayed onto another draft or revision. A retry of the same command
  gets its stored receipt (ADR 0007).

### Host device

- The CLI on the server's host talks to the server over a Unix domain socket in the server's state
  directory, which is mode 0700, with the socket 0600.
- It authenticates with both the peer's uid, which must equal the server's, and a 256-bit **host
  secret**, compared in constant time. A refusal says nothing about which check failed.
- The server writes a new host secret at every start, to a 0600 file in its state directory.
  Like the database files, that directory is outside every action's file scope (I14). The socket
  and the secret file are `host/`'s ([ADR 0012](0012-node-interface.md)).
- The CLI is a client in ADR 0006's sense: the server keeps one `dev_…` device of kind `host` for
  it. Its secret rotates, but its `deviceId` doesn't.
- **It is the one device `RevokeDevice` refuses**, and restores, identity resets and
  `RevokeSelf` leave it as it is. It stands for access to the host as the server's OS user,
  which revocation can't take away. Restarting the server replaces its secret.
- Instead of scopes, it holds a fixed allow-list: mint pairing payloads, list devices, revoke
  devices, confirm suspended devices, rename the server, reset the server's identity, and
  configure TLS modes and webhook intake. Anything else, including every approval, mode,
  permission and pre-approval command, is refused with `permission_denied` and no
  `PresenceRequired`.

### Revocation

- A device is revoked in one of five ways:
  - by `RevokeDevice` from another device with `admin` and presence
  - by `RevokeSelf` from itself
  - from the host CLI
  - by a re-pair's `replaces` proof ([ADR 0019](0019-pairing-profiles.md))
  - by `majula identity reset`, which revokes every device but the host device
    ([ADR 0018](0018-server-identity-trust.md))
- Each runs the same steps. The command marks the device revoked and cancels the unredeemed
  pairing records it minted. The `deviceId` is never reused.
- After the commit, the server drops the device's tokens and ends its open streams with
  `unauthenticated`, through ADR 0010's registry and the revocation check in each read. A
  `server` command then ends Bypass on any session the device turned on, through ADR 0005's
  existing transition.
- **Revocation takes effect on the next request and on open streams.** What already happened
  stands:
  - A batch or transcript item already sent isn't recalled (ADR 0010).
  - An approval committed before the revocation stands, and its effect still runs.
  - dc's edit lock on a gate is a lease (ADR 0004). The revoked device's renewals are refused,
    and the lease lapses through its existing 5-minute expiry; revocation adds no ADR 0004
    transition.
- Devices are server records, kept forever (ADR 0014). The list shows each device's name,
  platform, key protection, scopes, when it paired, who minted its payload, and when it was last
  seen. `Authenticate` updates last-seen at most once an hour. Devices don't expire from
  inactivity in v1.
- Each new pairing appears in the cockpit's attention set on every other device, naming the
  device, who minted its payload and when, with a way to revoke it in one tap.

### Devices after a restore

- A restored database can hold devices that were revoked after the backup was taken.
  `majula restore` (job 2.1) marks every restored device but the host device `suspended`, and
  `Authenticate` refuses it with `DeviceSuspended` until dc confirms it on the host with
  `majula devices confirm`.
- A database file copied in by hand skips this, which is out of scope.

### Push

- v1 has no remote push. A later relay stores each push registration against a `deviceId` and
  deletes it when that device is revoked.

## Alternatives

- **One long-lived bearer secret per device, as Outpost's hook server uses.** Anything that copies
  it uses it from anywhere, which I11 rules out.
- **Signing every request with the device key.** StrongBox signatures are slow, and every call
  would cost a hardware operation.
- **DPoP-style proofs with a short-lived software key the device key certifies.** It closes the
  window an in-memory token leaves, but needs a custom signature on every request across three
  Connect stacks. It's the upgrade if that window proves too wide.
- **Signed stateless tokens, such as JWTs.** The server checks the device on every call for
  revocation anyway, so signing adds key management and nothing else.
- **Tokens stored in the database.** They'd outlive restarts as domain state, with nothing gained.
- **One key for authentication and presence.** Every call, background reconnects included, would
  prompt dc.
- **Key attestation through App Attest or Android Key Attestation.** It needs platform roots and
  works differently on Mac, iPhone and Android. Deferred.
- **The CLI authenticated by uid alone.** Agent sessions run as the same OS user.
- **The CLI as the `server` actor.** The record would lose that dc acted at the host.

## Consequences

- Job 2.6 builds `Authenticate`, the token map, the interceptor that checks token, device, scope
  and presence, `RevokeDevice` and `RevokeSelf` with their stream close, `SetDeviceScopes`, the
  host socket and device, and the attention entry for new pairings. Its done criterion, that a
  revoked device stops within one request, covers open streams.
- Job 2.1 suspends restored devices.
- Jobs 3.8 and 3.9 run the key spikes, then store each profile's keys in the Keychain or Keystore.
- Every job that adds an RPC declares its scope, and every job that adds a command says whether it
  needs presence.
- Changing what a token proves, letting a device without a presence key hold `approve` or
  `admin`, or letting a client choose its `deviceId` needs an ADR that supersedes this one.

## Security

This touches T1 × B1, T1 × B2, T1 × B6, T3 × B1 and T2 × B2.

- **I8 (T1 × B1, T3 × B1):** every call is authenticated, `Authenticate` by a device-key signature
  whose timestamp and nonce bound replay.
- **I10 (T1 × B1):** a revoked device is refused on its next call, its tokens are dropped and its
  streams end, from another device or the host CLI.
- **I11 (T1 × B1, T1 × B6):** the device key can't be exported, and the access token lives only in
  memory for at most an hour. Approving and widening need the presence key, whose proof is bound
  to one command's payload, and each profile has its own.
- **I5, I11 (T1 × B2):** entering Bypass needs presence, and Bypass ends when its device is
  revoked.
- **I6, I13, T2.14 (T2 × B2):** a session can't reach the host secret through its file scope, and
  the uid check alone doesn't admit it.
- **R1 reaches further than the database.** Code a session runs as the server's OS user can read
  the host secret, mint a payload over the socket and redeem it for a device with `approve` and
  `admin`, then approve gates and enter Bypass with a software presence key. Under R1 that's
  A8, not only A9. Job 1.8 owns R1. Until it closes this, the only check is detection: every new
  pairing shows on dc's other devices with one-tap revoke.
- **I14:** no device private key reaches the server. Pairing secrets and tokens are stored only as
  hashes, and the host secret is a 0600 file outside every action's scope.

R1 stands, and now reaches A8 through the host socket, as above. R2 stands. A6 in the threat
model now names presence keys, access tokens and pairing secrets.
