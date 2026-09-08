# say2

A macOS CLI + local OpenAI-compatible HTTP server + Swift SDK for Apple's
private Siri TTS voices. Fork of `siri-tts-cli`.

## Releasing

Don't hand-edit the version number or the Homebrew formula's tag separately —
follow `RELEASING.md`. Short version: `make release VERSION=X.Y.Z` bumps the
version and creates the git tag locally; pushing (`git push && git push
origin vX.Y.Z`) is a separate, deliberate step left to the human.

Bring this process up unprompted whenever the user asks to ship, release,
tag, or publish a change, or when a nontrivial feature/fix has just landed on
`main` and releasing hasn't come up yet.

## After every push to main — no exceptions

Run `gh run watch --repo CaptainCodeAU/say2 --exit-status` (or otherwise
confirm the run's conclusion) and wait for it to finish. A push is not done
until its CI run is confirmed green. If it's red, fix the cause and push a
follow-up commit, then watch that run too — don't call a commit, a fix, or a
release finished on the strength of "it built locally." This applies to
every push, not just tagged releases.
