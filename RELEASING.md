# Releasing say2

One script does the mechanical part. You still decide *when* to release, and
you still run the command that makes it public — the script stops short of
that on purpose.

## Versioning

Semantic versioning, `X.Y.Z`:

- **patch** (`1.0.1`) — bug fix, no behavior change a user would notice in normal use
- **minor** (`1.1.0`) — new flag, new command, new capability, backward compatible
- **major** (`2.0.0`) — a documented CLI flag, exit code, or JSON schema changes in a way that breaks existing scripts

## Steps

1. Make sure `main` is clean and has everything you want in the release.
2. Run:
   ```sh
   make release VERSION=X.Y.Z
   ```
   (equivalent to `./scripts/release.sh X.Y.Z`)

   This runs the test suite, bumps `say2Version` in `Sources/Say2Core/Models.swift`,
   updates the tag reference in `Formula/say2.rb`, commits both, and creates the
   git tag `vX.Y.Z` — all locally. It refuses to run on a dirty working tree, on
   a branch other than `main`, or if that tag already exists.
3. Optional but recommended before publishing — exercise a real voice:
   ```sh
   make smoke
   ```
4. Publish it. This is the one step the script deliberately leaves to you:
   ```sh
   git push && git push origin vX.Y.Z
   ```
5. `brew install CaptainCodeAU/say2/say2` (or `brew upgrade`) now picks up the new tag.

## What CI checks automatically

`.github/workflows/ci.yml` builds and runs the unit test suite on every push
and pull request. If that's red, treat the branch as not release-ready
regardless of what `release.sh` would let you do locally — the script can't
see CI status before you've even pushed.

Live tests that need a real installed Siri voice can't run on GitHub's
runners, so they're not part of CI. Run `make live-test` yourself before a
release if you changed anything in the synthesis path.
