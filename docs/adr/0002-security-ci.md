# 0002. Security CI

- Status: Accepted
- Date: 2026-11-25

## Context

Roadmap job 1.1 asks for a code scan, a secret scan and dependency update PRs on every PR and
push to `main`. The repo is public, so CodeQL runs and uploads results without a GitHub Code
Security license. CodeQL default setup is not configured. GitHub secret scanning, push protection
and Dependabot security updates are already enabled in the repo settings.

## Decision

- **Code scan: CodeQL advanced setup** in `.github/workflows/codeql.yml`, for
  `javascript-typescript` and `actions`, with `build-mode: none`. It runs on pull requests, on
  pushes to `main` and weekly.
- **Secret scan: the gitleaks CLI** in `.github/workflows/secret-scan.yml`. The job downloads a
  pinned gitleaks release, verifies its SHA-256 and scans the full git history. Any finding fails
  the job.
- **Dependency updates: Dependabot version updates** for npm (the pnpm workspace root) and
  GitHub Actions, weekly, with minor and patch updates grouped into one PR per ecosystem.
- Every action is pinned to a full commit SHA with its version in a trailing comment, and every
  workflow sets least-privilege `permissions:`.

## Alternatives

- **CodeQL default setup.** It's configured outside the repo, so it's invisible in review, and
  its check can't be required by a job name the repo controls.
- **Semgrep CE.** Only needed if CodeQL can't upload results, which is the case for a private repo
  without Code Security.
- **`gitleaks/gitleaks-action`.** It needs a paid license key on organization-owned repos.
- **The gitleaks container image.** Running git inside the container on a checkout owned by the
  runner user trips git's `safe.directory` check, and the image digest has to be bumped by hand
  just like a release checksum.
- **trufflehog OSS.** It works too, but gitleaks is lighter and its `.gitleaksignore` handles
  false positives simply.
- **Scanning only the pushed or PR commit range.** The history is small enough that a full scan
  costs seconds, and it avoids the edge cases of a branch's first push.

## Consequences

- The job names `codeql (javascript-typescript)`, `codeql (actions)` and `secret-scan` are a
  stable contract, because branch protection requires them by name. The `codeql` jobs pass even
  when they find alerts. Only GitHub's `CodeQL` results check fails on new alerts, so branch
  protection must require it too.
- Dependabot doesn't track the gitleaks version in `secret-scan.yml`. Bump the version and its
  checksum by hand.
- The scan covers every fetched branch, so a secret pushed to any branch, even an abandoned one,
  fails `secret-scan` on every run. A leaked secret stays in history, so after rotating it, add
  its fingerprint to `.gitleaksignore`.
- Making the repo private without Code Security breaks the CodeQL upload, and switching to
  Semgrep would need an ADR that supersedes this one.
