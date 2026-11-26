# 0003. API schema technology

- Status: Accepted
- Date: 2026-11-26

## Context

The roadmap provisionally chose Protobuf + Connect RPC for the client/server API, with OpenAPI and
a WebSocket JSON protocol as the alternative, pending the job 1.6 spike. Its client/server contract
needs one schema that the TypeScript server and the Swift and Kotlin clients all generate their API
code from, with streams that carry small whole entities. Job 1.5 sets API conventions on top of
this decision, and job 1.7 designs trust and pairing on top of its transport.

The spike ran a Connect server with TypeScript, Swift and Kotlin clients: unary and server-streaming
calls over HTTP/2, bearer auth, a private-CA trust root with a rotating leaf, and resume after
mobile backgrounding. All three clients pass, with gaps: the TypeScript tests ran on Node 25, not
22, and neither app ran on a real device. See [the findings](../spikes/1.6-api-spike.md).

## Decision

- **Protobuf + Connect RPC.** The schema lives in `proto/` in this repo. The server uses
  `@connectrpc/connect-node` on `node:http2`. The Apple client uses connect-swift and the Android
  client connect-kotlin.
- **Unary and server-streaming calls only.** Adding bidi streaming needs an ADR that supersedes
  this one.
- **Codegen with buf**, using v2 config and one `buf.gen*.yaml` template per target. TypeScript
  uses the local `protoc-gen-es` plugin from npm. Swift and Kotlin use BSR remote plugins pinned
  to exact versions. Generated code is committed wherever it's generated. Where the Swift and
  Kotlin code is generated and how it's packaged is job 2.3's.
- **Trust root.** Job 1.7 builds on this:
  - A client's only trust anchor is a long-lived private CA or long-lived server key that it pins,
    never a leaf.
  - Leaves are short-lived and rotate with no client change. Apple rejects leaves valid for more
    than 825 days; the spike's lasted one day.
  - Clients keep the platform's full evaluation of chain, expiry, hostname and EKU. An SPKI pin
    may be added on top, only as defence in depth.
  - Clients keep their own signal for a trust rejection, because, as far as the spike saw, Connect
    reports it as a cancel or an unknown error.
  - No ATS exception and no Android `network_security_config` are needed.
  - Prefer the private CA. It's the variant the spike tested; a raw pinned server key wasn't.

## Alternatives

- **OpenAPI + a WebSocket JSON protocol.** OpenAPI doesn't describe WebSocket messages, so streams
  would need a second schema or hand-written types in all three clients, which breaks the
  one-schema contract. It also means two protocols to secure and authenticate, and resume built by
  hand on a raw socket. Its one real advantage: custom trust on Apple would be easy, because
  `URLSessionWebSocketTask` uses the app's own session delegate. With Connect, that costs a custom
  transport.
- **gRPC.** It needs HTTP/2 trailers, so grpc-swift and NIO on Apple, and doesn't run over
  HTTP/1.1. Connect servers speak the gRPC protocol too, so nothing is lost by choosing Connect.
- **protoc.** It has none of buf's v2 config, remote plugins or `buf lint`, nor the
  `buf breaking` that job 1.5 wants in CI.
- **Generating code at build time.** Every build would need buf and a reachable BSR, and changes to
  the generated code would be invisible in review.

## Consequences

- connect-swift's `URLSessionHTTPClient` can't take a custom trust root, so the Apple client
  carries its own URLSession `HTTPClientInterface` until connect-swift exposes a hook, or moves to
  `NIOHTTPClient`. Job 3.8 owns it, starting from the spike's known gaps.
- connect-kotlin's default timeout ends streams after 10 s, so the Android client disables the
  stream timeout.
- Job 1.5 sets versioning, errors and pagination on top of this, and adds `buf breaking` to CI.
- How the client repos get their generated code from `proto/` is job 2.3's. Each still needs a
  schema-drift check against `proto/` (jobs 3.8 and 3.9).
- The Connect and protobuf-es npm packages are Apache-2.0, already on the license allowlist.
- The BSR is a network dependency when generating code, not when building.
- Moving off Connect needs an ADR that supersedes this one.

## Security

This touches T3 × B1, T1 × B1 and T4 × B1.

- **I9:** clients authenticate the server through a pinned private CA or long-lived key with full
  platform evaluation, never a pinned leaf or network position.
- **I8:** every RPC except those I8 exempts (pairing redemption and a health check) authenticates
  its caller. The spike's interceptor covered both its RPCs, and unary calls and streams both
  rejected a missing or wrong token.
- **I10:** open for job 1.7. Connect checks auth when a call starts, so revocation has to be built
  to reach open streams.
- **I11:** unaffected. Approval provenance is designed by jobs 1.4 and 1.7, and the transport
  doesn't change it.
- **I17:** the BSR plugins are pinned to exact versions and `protoc-gen-es` by the lockfile, and
  generated code is committed, so a codegen change reaches `main` as a reviewed diff through the CI
  gate.

The threat model is unchanged.
