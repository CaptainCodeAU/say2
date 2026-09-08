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
