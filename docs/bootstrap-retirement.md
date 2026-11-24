# Bootstrap retirement

## What is in the tree

The canonical compiler is `harmony`, built from `harmony/` + `library/` by the
frozen stage-0 seed at `bootstrap/seed/harmony-seed`. That seed is a
byte-identical stage-1 build of the compiler itself; `make verify-seed` checks
its checksum and `make qualify-seed` re-proves stage1 == stage2 == stage3.

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

## Manual follow-ups

These steps need a GitHub token and a web session. They could not be performed
from the build environment (no `gh` CLI or token), so they are recorded here
as explicit follow-ups rather than silently skipped.

### 1. Publish the `v0.3.3` legacy seed/archive release

Run from a checkout with credentials and `gh` installed. Create the release
tag from the **legacy** tag, not from `master` (the CI `Release: tag`
workflow only runs on the default branch and would tag the post-cutover
commit):

```bash
git fetch origin --tags
git tag -a v0.3.3 legacy/bootstrap-final \
  -m "Harmony v0.3.3 — legacy bootstrap seed and oracle archive"
git push origin v0.3.3
gh release create v0.3.3 \
  --target legacy/bootstrap-final \
  --verify-tag \
  --title "Harmony v0.3.3 — legacy bootstrap seed" \
  --notes "Frozen c2x-seed + harmony-base toolchain, golden oracle outputs and two-lane harness. Preserved on \`legacy/bootstrap\` / \`legacy/bootstrap-final\`; superseded by the seed-only build on master."
```

Pushing `v0.3.3` will change `git describe` for `master`, so regenerate the
stamp afterwards with `make version` and commit the one-line `VERSION` change.
Do **not** run `Release: tag` on `master` until the version base is bumped to
`1.0.0`; the workflow validates the tag against `VERSION`.

### 2. Protect branches and tags

In GitHub → Settings → Branches / Tags, add rules so the freeze cannot be
lost accidentally:

- `master`: require a pull request, dismiss stale approvals, require the CI
  build/test checks, block force pushes and deletion.
- `legacy/bootstrap`: block force pushes and deletion (it is the only
  preserved copy of the legacy tree).
- `v*` and `legacy/*` tags: prevent deletion (or restrict deletion to
  maintainers).

### 3. Archive the GitLab mirror

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
