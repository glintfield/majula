# CLAUDE.md

Majula's server repo: server, CLI, protocol schema and ADRs. pnpm workspace, TypeScript (ESM,
strict) on Node 22.

## Layout

- `server/` (`@majula/server`), `cli/` (`@majula/cli`): workspace packages. Each `tsconfig.json`
  extends the strict root `tsconfig.base.json`.
- `proto/`: placeholder for the API schema until job 1.6 picks the tooling. Don't add codegen.
- `docs/adr/`: architecture decision records. See `docs/adr/README.md`.
- `docs/policy/`: policies Majula's code must follow. `agent-terms.md` says which runtime
  credentials, logins and usage sources are allowed.
- `docs/threat-model.md`: assets, trust boundaries, attackers and security invariants. Design docs
  cite its IDs.
- `docs/spec-template.md`: the template every design doc copies, including a Security section
  filled in against the threat model.
- `scripts/`: repo tooling (`check-licenses.mjs`).

## Setup

```sh
corepack enable
pnpm install
```

`engineStrict` is on, so installs fail on any Node other than 22.

## The CI gate

Run all five before pushing. CI runs each as its own job, and branch protection requires the job
names, so don't rename them.

| Command              | CI job          |
| -------------------- | --------------- |
| `pnpm lint`          | `lint`          |
| `pnpm format`        | `format`        |
| `pnpm typecheck`     | `typecheck`     |
| `pnpm test`          | `test`          |
| `pnpm license-check` | `license-check` |

- `pnpm format:fix` fixes formatting.
- `pnpm test` passes with no test files, so a new package doesn't need a placeholder test.
- `pnpm license-check` fails on any production dependency whose license isn't on the allowlist in
  `scripts/check-licenses.mjs`. Widening the allowlist needs an ADR.
- The `codeql` and `secret-scan` workflows add the jobs `codeql (javascript-typescript)`,
  `codeql (actions)` and `secret-scan`. They have no local command, and their names are just as
  stable. The `codeql` jobs pass even when they find alerts, so branch protection must also
  require GitHub's `CodeQL` check, which fails on new alerts. See ADR 0002.

## Conventions

- Record architecture and tooling choices as an ADR in `docs/adr/`.
- Write a design doc by copying `docs/spec-template.md` to `docs/design/`. Spikes and steps
  marked _(no design doc)_ skip it.
