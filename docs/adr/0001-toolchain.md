# 0001. Toolchain

- Status: Accepted
- Date: 2026-11-25

## Context

The server and CLI are TypeScript on Node 22 LTS. The repo starts empty, and every later job
needs a CI gate that runs lint, format, typecheck, tests and a dependency license check. The
roadmap also requires a lint rule, added in jobs 2.2/3.1, that stops the core from importing git,
the filesystem or agent runtimes directly. Whatever linter is chosen must be able to express
that.

## Decision

- **Package manager: pnpm workspaces**, pinned through `packageManager` and corepack. `server/`
  and `cli/` are workspace packages.
- **Lint: ESLint (flat config) with typescript-eslint `strictTypeChecked`.** The core-boundary
  rule will be ESLint's built-in `no-restricted-imports`, scoped with `files`.
- **Format: Prettier**, checked in CI and kept out of the ESLint config.
- **Typecheck: `tsc -b`** over project references. Every package extends one strict
  `tsconfig.base.json`.
- **Tests: Vitest**, with `passWithNoTests` so a new package needs no placeholder test.
- **License check: `scripts/check-licenses.mjs`**, which reads `pnpm licenses list --prod` and
  fails on any production dependency whose SPDX expression can't be satisfied from the allowlist.
  - The allowlist: MIT, MIT-0, ISC, BSD-2-Clause, BSD-3-Clause, 0BSD, Apache-2.0, Unlicense,
    CC0-1.0, BlueOak-1.0.0, Python-2.0, Zlib.
  - Weak copyleft (MPL, LGPL) and CC-BY are left out on purpose.

## Alternatives

- **npm workspaces.** No install step, but its loose hoisting lets a package import dependencies
  it doesn't declare. That undermines the boundaries the core-import rule exists to keep.
- **Bun.** The server must run on Node 22, and a second runtime used only for tooling adds drift.
- **Biome** for lint and format. Faster, and it has `noRestrictedImports`. But it lacks
  typescript-eslint's type-aware rules (`no-floating-promises`, `no-misused-promises`), which
  matter most in an async daemon.
- **`node:test`.** No dependency, but running TypeScript needs Node 22's experimental type
  stripping or a loader.
- **Jest.** Needs ESM and TypeScript transform configuration.
- **license-checker and its forks.** They walk `node_modules`, which is unreliable under pnpm's
  symlinked layout, and most mishandle SPDX expressions.

## Consequences

- The CI job names `lint`, `format`, `typecheck`, `test` and `license-check` are a stable
  contract, because branch protection requires them by name.
- Adding a production dependency with a license outside the allowlist needs a new ADR that widens
  it.
- typescript-eslint's peer range sets the TypeScript version, which is pinned to 6.0.x for now.
