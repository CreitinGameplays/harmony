# Bootstrap retirement

## What is in the tree

The canonical compiler is `harmony`, built from `harmony/` + `library/` by a
frozen stage-0 seed: a byte-identical stage-1 build of the compiler itself.
The binary is **not** kept in git. It is published on the `stage0-v1` release
and downloaded by `make harmony` into gitignored `build/seed/`, verified against
`bootstrap/seed/SHA256SUMS` before it runs. `make verify-seed` re-checks it and
`make qualify-seed` re-proves stage1 == stage2 == stage3. `SEED_BIN` pins a local
copy for offline builds; `SEED_URL` selects a mirror.

**Seed policy:** the latest compiler release is always the next seed (AGENTS.md).
Each new release publishes its compiler binary as the new seed asset, updates
`bootstrap/seed/SHA256SUMS` and `SEED_URL`, and re-qualifies it with
`make qualify-seed`. Older seed assets remain available for reproducing past
builds but are no longer the default. The current seed is `stage0-v1`; the
first seed-native final release is `1.0.0`.

`make test` is a single lane. The legacy `c2x-seed` / `harmony-base` toolchain,
the frozen oracle outputs in `tests/golden/v0.3.3/`, the `HARMONY`/`ORACLE`
lane switches and the legacy-only suites are **not** in this tree. That
includes `tests/harmony/coverage.sh`: its baseline counted symbols in the
legacy compiler's static binary and measured LLD internals once the compiler
linked libLLVM dynamically, so keeping it would have been a silent no-op. The
fuzz gates (`make test-fuzz`, `make test-fuzz2`, `make fuzz2-deep`) remain.
Everything retired here is preserved, unmodified, on:

- branch `legacy/bootstrap` (pushed to `origin`)
- annotated tag `legacy/bootstrap-final` (pushed to `origin`)

Legacy commits remain in `master`'s history. No history was rewritten and no
commit was force-pushed; the separation is current-tree only. The version line
stays `0.3.3-dev`: there is no `0.4.0`, and the first seed-native final release
is `1.0.0`.

## Follow-up status

### 1. `v0.3.3` legacy seed/archive release — done

Published at <https://github.com/CreitinGameplays/harmony/releases/tag/v0.3.3>,
tagged from the legacy commit (`643a04d`) rather than master. Assets: a source
archive of the frozen tree and its `SHA256SUMS`. The `VERSION` stamp was
regenerated after the tag because `git describe` now sees `v0.3.3`.

The CI workflow skips **every** job for `refs/tags/v0.3.3`. Without those
guards the tag push started a tag run that would have published the master
binary over the archive release; that run was cancelled. Do **not** run
`Release: tag` on `master` until the version base is bumped to `1.0.0`.

### 2. Branch/tag protection — branches done, tags blocked

`master` requires a pull request, dismisses stale approvals, requires the
`Build` and `Test` checks, and blocks force pushes and deletion.
`legacy/bootstrap` blocks force pushes and deletion. Admins can still bypass
(`enforce_admins: false`) so maintenance commits remain possible.

Protected **tags** could not be configured: both `POST /tags/protection` and
the GraphQL `createTagProtectionRule` mutation return 404/undefined on this
repository's GitHub plan. Until that changes, treat `v0.3.3` and
`legacy/bootstrap-final` as manually protected — do not delete or force-move
them.

### 3. Archive the GitLab mirror — pending

The `gitlab` remote is still reachable but no `glab` CLI or GitLab API token
is available here, so the archive must be done in a browser (or with a PAT):

1. Confirm nothing depends on GitLab CI or its issue tracker.
2. GitLab → Project settings → General → Archive the project
   (<https://gitlab.com/CreitinGameplays/harmony/-/settings/general>).
3. Remove the `gitlab` remote locally (`git remote remove gitlab`) and from
   any collaborator checkouts. Do **not** configure push mirroring from GitLab
   toward GitHub — GitHub is the source of truth.

`gitlab` still points at `git@gitlab.com:CreitinGameplays/harmony.git` and is
behind `origin`. Once the GitHub state above is verified:

1. Confirm nothing depends on GitLab CI or its issue tracker.
2. GitLab → Project settings → General → Archive the project.
3. Remove the `gitlab` remote locally (`git remote remove gitlab`) and from
   any collaborator checkouts. Do **not** configure push mirroring from GitLab
   toward GitHub — GitHub is the source of truth.

### 4. First seed-native release

When the final language is ready, bump the `VERSION` base to `1.0.0` on a
`1.0` release branch and run the CI `Release: tag` workflow. That release is
built entirely from the seed-only path; no legacy compiler is involved.
