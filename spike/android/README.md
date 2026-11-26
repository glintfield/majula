# Kotlin client spike (roadmap job 1.6)

A throwaway Connect-Kotlin client for `spike.v1.SpikeService`, tested on the Android emulator
against the spike server in `../server`. A later job deletes this directory with the rest of
`spike/`.

## Run the tests

Prerequisites: JDK 17, the Android SDK with an emulator system image and an AVD, Node 22, and
`npm --prefix spike install`. No system `gradle` is needed; the wrapper is committed.

```sh
spike/android/scripts/test.sh
```

The script:

1. Creates a private CA and a second unknown CA in a temp dir.
2. Starts the server on port 18443 and rotates its leaf with `SIGHUP`.
3. Boots the AVD headless (`-no-window`) unless an emulator is already running.
4. Runs `./gradlew connectedAndroidTest`, passing the URL, token, both CAs and the initial leaf's
   fingerprint as instrumentation arguments.

It stops the server, the emulator it booted and deletes the certs on exit.

| Env var        | Default                        | Meaning                        |
| -------------- | ------------------------------ | ------------------------------ |
| `SPIKE_PORT`   | `18443`                        | Port for the test server       |
| `SPIKE_AVD`    | `magetd_test`                  | AVD to boot if none is running |
| `JAVA_HOME`    | `/opt/homebrew/opt/openjdk@17` | JDK for Gradle                 |
| `ANDROID_HOME` | `~/Library/Android/sdk`        | Android SDK                    |

Without the harness's arguments, the tests skip themselves.

## Layout

- `app/`: the only module.
  - `src/main/java/spike/v1/`, `src/main/kotlin/spike/v1/`: generated code.
  - `SpikeConnection`: builds a client from a URL, token and CA.
  - `TrustObserver`: an OkHttp `EventListener` that records protocols, served leaves and trust
    rejections.
  - `ResumableWatch` and `MainActivity`: stream `Watch` and resume after backgrounding.
  - `src/androidTest/`: the instrumented tests.
- `scripts/test.sh`: the harness.

Regenerate the Kotlin code with `npm --prefix spike run generate:kotlin`. It uses
`../buf.gen.kotlin.yaml` with the BSR remote plugins `buf.build/protocolbuffers/java` (`lite`) and
`buf.build/connectrpc/kotlin`.

## Findings

Measured with connect-kotlin 0.10.0, OkHttp 5.5.0, protobuf-javalite 4.36.2, Kotlin 2.4.21, AGP
9.5.3 and Gradle 9.9.2, on the `magetd_test` AVD (Pixel 6, Android 15 / API 35, arm64-v8a
google_apis) on an Apple Silicon Mac. minSdk 29, targetSdk 35, compileSdk 37. All 8 tests pass.

### Transport

**Server-streaming works on OkHttp over HTTP/2.**

- `unary` asserts the connection's protocol is `HTTP_2`. The server also accepts HTTP/1.1, so a
  silent downgrade would otherwise go unnoticed.
- `stream` and `resume` read events off the response channel as they arrive.
- connect-kotlin's default `timeoutOracle` gives **every** call, streams included, a 10 s
  deadline. A long-lived `Watch` needs `simpleTimeouts(unaryTimeout, streamTimeout = null)`, or
  it ends after 10 s.
- Bidi streaming wasn't tested; the proto has none.

### Custom trust

**connect-kotlin takes a custom trust root with no workaround.** This is the opposite of
connect-swift.

- `ConnectOkHttpClient` takes any `OkHttpClient`. The spike builds one with okhttp-tls
  `HandshakeCertificates.Builder().addTrustedCertificate(ca)` and no platform roots, and passes
  its `sslSocketFactory` and `trustManager`. That's about 10 lines.
- This anchors on the CA and keeps OkHttp's chain, expiry and hostname checks. IP SAN
  `10.0.2.2` matched with no extra configuration.
- An SPKI `CertificatePinner` on the CA key was rejected. A pinner only filters chains that
  trust has already accepted, and platform trust rejects the private CA, so a pinner alone
  can't work. It could be layered on in 1.7 as defence in depth.

**Leaf rotation is invisible to the client.** `rotatedLeaf` asserts that the served leaf differs
from the one the server started with and that its call succeeds. The same untested caveat as
Swift applies: an open HTTP/2 connection keeps the leaf it handshook with.

**An unknown CA is rejected.**

- `wrongCA` asserts no response and exactly one recorded rejection.
- `retryOnConnectionFailure(false)` keeps it to one connect attempt per call.
- connect-kotlin surfaces the rejection as Connect `UNKNOWN`, wrapping
  `CertPathValidatorException: Trust anchor for certification path not found`. That's
  indistinguishable by code from other I/O failures, so a real client should keep its own
  rejection signal, like `TrustObserver`, as on Swift.

### Android network security config

**None was needed.**

- `network_security_config` governs the platform's default trust manager and cleartext policy.
  OkHttp with its own `X509TrustManager` bypasses the former, and every call is HTTPS.
- The manifest needs only `INTERNET`.
- A `<trust-anchors>` entry would also have been impractical here: the harness makes a fresh CA
  each run, so it can't be baked into resources.

### Backgrounding

**Reconnect after backgrounding works with an explicit stop and start.**

- `MainActivity` runs the stream inside `repeatOnLifecycle(STARTED)`. That cancels it on
  `onStop`, restarts it on `onStart`, and passes `after_seq` set to the last seq received. It's
  the equivalent of Swift's `scenePhase` handling.
- `resumesAfterBackgrounding` streams, then presses Home with UiAutomator and waits for the
  activity to stop. After 5 s it brings the activity back with
  `am start --activity-reorder-to-front`, as a launcher tap does. It asserts:
  - at least two connects;
  - `lastSeq` advanced at least 40, into the about 50 events emitted while away;
  - zero gaps or duplicates, which proves replay.
- `ActivityScenario.moveToState` wasn't used: it only drives the lifecycle, and isn't a real trip
  to the launcher.

**An un-cancelled stream kept running in the background.**

- `observeUncancelledStreamInBackground` leaves the stream open while stopped for 15 s. It
  asserts:
  - the stream is still `streaming` both before and after the return;
  - at least 100 of the roughly 150 events emitted while stopped arrived before the return;
  - zero gaps.
- Nothing restarts the stream in this mode, so a cut or frozen stream fails the test rather than
  being recorded.
- Its log line shows every event emitted while stopped arrived on the same connection: 148 and
  149 in two runs.
- So Android did nothing to the HTTP/2 connection in that window. It ran past the cached-app
  freezer's roughly 10 s delay.
- This does not show what a shipped app would see:
  - the instrumentation process isn't frozen or cached like an ordinary backgrounded app;
  - 15 s exercises neither Doze nor App Standby.
- Cancelling on stop, as above, is what a real app should do anyway, and makes the reconnect
  deterministic.

### Tooling

- **Gradle wrapper without a system `gradle`:** download `gradle-9.9.2-bin.zip` from
  services.gradle.org, check it against the published SHA-256, and run its `bin/gradle wrapper`
  once. The committed `gradle-wrapper.properties` pins `distributionSha256Sum`.
- **AGP 9 has Kotlin built in** and would compile with its bundled KGP 2.2.10. The root build
  declares `org.jetbrains.kotlin.android` 2.4.21 with `apply false` to match the Kotlin that
  connect-kotlin 0.10.0 is built with.
- **compileSdk 37:** okhttp-android 5.5.0's AAR metadata requires it. AGP installed SDK Platform
  37 on the first build, because the license was already accepted. targetSdk stays 35.
- **Codegen:** the BSR remote plugins were reachable with no login, like the Swift ones.
- **Emulator:** booted headless from a script with `-no-window -no-audio -no-boot-anim`. It took
  about 30 s to `sys.boot_completed` on this machine.
- **Node:** the machine has Node 25, not 22. The harness warns and the server runs fine.

### Known gaps

For 1.7 to pick up; none of these affect the tests above.

- `wrongCA` logs the Connect code but doesn't assert it.
- No test holds a connection across a leaf rotation.
- The backgrounding tests run on API 35 only. minSdk 29's lifecycle and freezer behaviour
  wasn't checked.
- `ResumableWatch` has no foreground reconnect loop. The Swift one retries with 250 ms to 5 s
  backoff and stops on terminal codes. Here, a network drop while foregrounded leaves the stream
  dead until the next `onStart`.
- `TrustObserver` counts any `SSLHandshakeException` or `SSLPeerUnverifiedException` as a trust
  rejection, including protocol or cipher mismatches. Before relying on it as a real rejection
  signal, 1.7 should narrow it to a `CertPathValidatorException` or `CertificateException` in the
  cause chain.
