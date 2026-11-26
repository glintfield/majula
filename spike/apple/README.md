# Swift client spike (roadmap job 1.6)

A throwaway Connect-Swift client for `spike.v1.SpikeService`, tested on macOS and the iOS simulator
against the spike server in `../server`. A later job deletes this directory with the rest of
`spike/`.

## Run the tests

Prerequisites: Xcode in `/Applications/Xcode.app` with an iOS simulator runtime, Node 22, and
`npm --prefix spike install`.

```sh
spike/apple/scripts/test.sh
```

The script:

1. Creates a private CA and a second unknown CA in a temp dir.
2. Starts the server on port 18443 and rotates its leaf with `SIGHUP`.
3. Runs three `xcodebuild test` passes:
   - the `SpikeClient` package tests on macOS;
   - the same tests on the iOS simulator;
   - the `SpikeHost` backgrounding UI test on the simulator.

It stops the server and deletes the certs on exit.

| Env var         | Default     | Meaning                                    |
| --------------- | ----------- | ------------------------------------------ |
| `SPIKE_PORT`    | `18443`     | Port for the test server                   |
| `SPIKE_SIM`     | `iPhone 17` | Simulator device name                      |
| `DEVELOPER_DIR` | Xcode.app   | Overrides `xcode-select`, which may be CLT |

Opening the package or `SpikeHost.xcodeproj` in Xcode works, but the tests skip themselves
without the harness's `TEST_RUNNER_*` environment.

## Layout

- `SpikeClient/`: Swift package.
  - `Generated/`: generated code.
  - `AnchoredHTTPClient`: a URLSession transport that trusts only the given CA.
  - `BearerAuthInterceptor`
  - `SpikeConnection`: builds a client from a URL, token and CA.
  - The tests.
- `SpikeHost/`: hand-written `SpikeHost.xcodeproj`.
  - A SwiftUI app whose `ResumableWatch` streams `Watch` and resumes after backgrounding.
  - The `BackgroundingUITests` XCUITest.
- `scripts/test.sh`: the harness.

Regenerate the Swift code with `npm --prefix spike run generate:swift`. It uses
`../buf.gen.swift.yaml` with the BSR remote plugins `buf.build/apple/swift` and
`buf.build/connectrpc/swift`.

## Findings

Measured with Xcode 27.2, connect-swift 1.2.3 and swift-protobuf 1.41.0, on macOS 26.6.2 and the
iPhone 17 simulator (iOS 27.0, deployment target 17.0). All 13 tests pass.

### Transport

**Server-streaming works on URLSession over HTTP/2.** NIO isn't needed.

- `testUnary` asserts the recorded ALPN protocols contain `h2`. The server also accepts
  HTTP/1.1, so a silent downgrade would otherwise go unnoticed.
- Events arrive as they're sent. `testStream` never sees the stream end, so it can only pass
  if frames are delivered incrementally. Its duration in the result bundle was about 0.47 s
  for five events at 100 ms. That timing was observed, not asserted.
- Bidi streaming wasn't tested. This transport buffers the request body until close, so it
  can't do bidi. Upstream's `URLSessionStream` streams request bodies via
  `needNewBodyStream`, so URLSession's own limit is unprobed.

### Custom trust

**connect-swift's `URLSessionHTTPClient` can't take a custom trust root.**

- The class is `open`, but its URLSession delegate is a private wrapper. The wrapper forwards
  only the data and task callbacks, never `urlSession(_:didReceive:completionHandler:)`. A
  subclass's challenge handler is therefore never called, and system trust rejects the private
  CA.
- `NIOHTTPClient`, by contrast, has an `open createTLSConfiguration(forHost:)` hook.
- The spike works around this with its own `HTTPClientInterface`, `AnchoredHTTPClient`, at about
  260 lines.
- 1.7 options:
  - keep a transport like this;
  - get a trust hook merged upstream;
  - use `NIOHTTPClient` and give up URLSession's system integration.

**Trust is anchored on the CA, never on the leaf.**

- The session-level challenge handler calls `SecTrustSetAnchorCertificates([ca])`, then
  `SecTrustSetAnchorCertificatesOnly(true)`, then `SecTrustEvaluateWithError`.
- This keeps Apple's full chain, expiry, hostname and EKU checks.
- Pinning the CA's SPKI hash was rejected: it means walking the chain by hand and still running
  an evaluation. It could be added in 1.7 as defence in depth.

**Leaf rotation is invisible to the client.**

- The harness rotates the leaf after the server starts and before any client runs.
- On both platforms, `testRotatedLeaf` asserts that the served leaf differs from the initial
  one and that its call succeeds.
- Expected but not tested: an already-open HTTP/2 connection keeps the leaf it handshook with,
  and only new connections see the rotated one. No test holds a connection across a rotation.

**An unknown CA is rejected.**

- Trust evaluation fails and the challenge is cancelled. The test asserts exactly one recorded
  rejection and no response.
- By construction, the cancel surfaces from URLSession as `URLError.cancelled`, which the
  transport maps to Connect `.canceled`. A real client should keep its own rejection signal,
  like `TrustObserver` here, rather than read `.canceled` as a user cancel.

### ATS and Apple's certificate rules

**App Transport Security needed no exceptions.** The leaf meets ATS:

- ECDSA P-256 signed with SHA-256;
- TLS 1.2+ with forward secrecy. The negotiated TLS version wasn't recorded.

**Apple's certificate rules:** checked against Apple's docs, not separately tested here.

- *Requirements for trusted certificates in iOS 13 and macOS 10.15* applies to every TLS server
  certificate:
  - names in the SAN (the CN is ignored);
  - the `serverAuth` EKU;
  - SHA-2 signatures;
  - RSA ≥ 2048 or ECDSA;
  - validity ≤ 825 days.
- *About upcoming limits on trusted certificates* (the 398-day cap) applies only to roots in
  Apple's trust store. It does not apply to a private CA anchored in code.
- The one-day leaf satisfies both.
- For 1.7, the long-lived CA can outlive these caps, because they cover leaves, not roots. Its
  leaves must still stay ≤ 825 days.

### Backgrounding

**Reconnect after backgrounding works with an explicit stop and start.**

- `SpikeHostApp` cancels the stream on `scenePhase == .background` and restarts it on `.active`,
  passing `after_seq` set to the last seq received.
- The UI test streams, presses Home for 5 s, then reactivates the app. It asserts:
  - at least two connects;
  - `lastSeq` advanced at least 40 past its pre-background value, into the about 50 events
    emitted while away;
  - zero gaps or duplicates. This is the proof of replay: a reconnect without `after_seq` would
    start at the live head and count a gap.
- Whether iOS would kill an un-cancelled suspended stream on its own wasn't measured. Explicit
  cancellation makes the reconnect deterministic, and is what a real app would do anyway.

### Tooling

- **Codegen:** the BSR remote plugins were reachable with no login. The generated code compiles
  in Swift 6 language mode with strict concurrency, and so does the rest of the package and app.
- **Project shape:**
  - A SwiftPM package carries the code and the unit tests. One test target runs on both
    platforms, because `xcodebuild test -scheme SpikeClient` takes either destination.
  - Only the iOS app and its UI test need an `.xcodeproj`. It's hand-written: Xcode 16+
    synchronized folders keep it to about 330 lines with no file list, and it built first try.
  - Signing is `CODE_SIGN_IDENTITY = "-"` with no team, so no developer account is needed.
- **Machine setup:**
  - `xcode-select` pointed at the Command Line Tools, which have no XCTest and no simulators. The
    harness sets `DEVELOPER_DIR` to Xcode.
  - The first simulator run also needed a one-time
    `sudo xcodebuild -runFirstLaunch` to update CoreSimulator, which was 1171.7 against the
    1174.21 that Xcode 27.2 expects.

### Known gaps

For 1.7 to pick up; none of these affect the tests above.

- `AnchoredHTTPClient` never removes unary exchange entries. URLSession calls no
  `didCompleteWithError` for completion-handler tasks, so the map leaks one entry per call.
- A non-200 stream response is closed before its body arrives, so the Connect error message is
  dropped.
- `testWrongCA` asserts the rejection and the missing response, but not the `.canceled` code
  that the trust section infers.
