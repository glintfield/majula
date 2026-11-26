# Majula

Majula is a self-hosted server that runs coding agents as jobs: editable plans, human-gated
writes, and a controller loop that shepherds pull requests to merge. Native clients for Mac,
iPhone and Android pair with it. It is built from Outpost, a personal tool, and is redesigned to
be installable and usable by anybody.

This repo holds the server, the CLI, the protocol schema and the design records. The apps live in
`noctana/majula-apple` and `noctana/majula-android`.

## Layout

| Path        | What it holds                                                 |
| ----------- | ------------------------------------------------------------- |
| `server/`   | The Majula server (`@majula/server`), TypeScript on Node 22   |
| `cli/`      | The `majula` command-line tool (`@majula/cli`)                |
| `proto/`    | The client/server API schema (placeholder until it is chosen) |
| `docs/adr/` | Architecture decision records                                 |
| `scripts/`  | Repo tooling, such as the dependency license check            |

## Development

Requires Node 22 (see `.nvmrc`) and pnpm, which corepack provides:

```sh
corepack enable
pnpm install
```

Every change must pass the same five checks CI runs:

```sh
pnpm lint
pnpm format
pnpm typecheck
pnpm test
pnpm license-check
```

`pnpm format:fix` rewrites files to the project's formatting.

Design decisions are recorded in [`docs/adr/`](docs/adr/README.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
