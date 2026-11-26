# API spike (roadmap job 1.6)

A throwaway Connect RPC server that the Swift and Kotlin spike clients test against. It serves
`spike.v1.SpikeService` over HTTP/2 TLS behind a bearer token, using a short-lived leaf
certificate signed by a long-lived private CA. A later job deletes this directory.

`spike/` is its own npm project and sits outside the repo's pnpm workspace and CI gate. Lint,
format, typecheck, test and license-check all skip it.

## Run the server

Use Node 22 (`nvm use` from the repo root).

```sh
npm --prefix spike install
npm --prefix spike run certs:init   # once: CA + first leaf in spike/certs/
npm --prefix spike start            # listening on https://127.0.0.1:8443
```

| Env var                   | Default           | Meaning                                    |
| ------------------------- | ----------------- | ------------------------------------------ |
| `SPIKE_HOST`              | `127.0.0.1`       | Bind address                               |
| `SPIKE_PORT`              | `8443`            | Port                                       |
| `SPIKE_TOKEN`             | `spike-dev-token` | Required `Authorization: Bearer` value     |
| `SPIKE_WATCH_INTERVAL_MS` | `1000`            | How often `Watch` emits an event           |
| `SPIKE_LOG_CAPACITY`      | `3600`            | Events kept for resume (about an hour)     |
| `CERT_DIR`                | `spike/certs`     | Where `leaf.key` and `leaf.crt` are read   |

`spike/certs/` is gitignored. Never commit it: the secret-scan CI job fails on private keys.

## Client setup

- **Trust root:** trust `spike/certs/ca.crt` as the only anchor. Pin the CA, never the leaf. The
  leaf lasts one day and rotates.
- **Auth:** send `Authorization: Bearer spike-dev-token` on every call. A missing or wrong token
  gets `unauthenticated`.
- **URL:** `https://localhost:8443` from the iOS simulator. `https://10.0.2.2:8443` from the
  Android emulator, which maps that address to the host's loopback. The leaf's SANs cover
  `localhost`, `127.0.0.1` and `10.0.2.2`.

## Rotate the leaf

```sh
npm --prefix spike run certs:rotate   # new leaf, same CA
kill -HUP <server pid>                # server reloads it without restarting
```

New connections get the new leaf. A client that trusts the CA keeps working; a client that
pinned the old leaf breaks.

## The contract

`proto/spike/v1/spike.proto`:

- `Echo(EchoRequest) returns (EchoResponse)`: returns the message unchanged.
- `Watch(WatchRequest) returns (stream Event)`: one shared event log, with a new `Event{seq,
  payload}` every interval. Seqs start at 1 and never skip.
  - `after_seq` unset: live events only.
  - `after_seq = N`: replays buffered events after `N`, then continues live. To resume after a
    reconnect, pass the last `seq` you received.
  - `failed_precondition`: `N + 1` has already fallen out of the buffer.
  - `out_of_range`: `N` is ahead of the latest event.

## Codegen

```sh
npm --prefix spike run generate
```

`buf.gen.yaml` writes TypeScript to `gen/ts/`, which is committed. Swift has its own template,
`buf.gen.swift.yaml` (`npm --prefix spike run generate:swift`), so regenerating TypeScript needs no
Swift plugins. Kotlin likewise has `buf.gen.kotlin.yaml` (`npm --prefix spike run generate:kotlin`).

## Tests

```sh
npm --prefix spike test
```

The tests start the server on a random port with a temporary CA. They cover the unary call, auth
rejection, streaming, gap-free resume and leaf rotation.

The Swift client and its tests are in `apple/`. See `apple/README.md`. The Kotlin client and its
tests are in `android/`. See `android/README.md`.
