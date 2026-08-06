# Versioning

NotchVoice uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html), tracked with
annotated git tags. The tag is the source of truth — the app reads its version from the
build, and the build reads it from the tag.

## Scheme

`MAJOR.MINOR.PATCH`

| Bump | When |
|---|---|
| MAJOR | A breaking change to how the app behaves for the user — a default hotkey change, a permission requirement added, stored history becoming unreadable. |
| MINOR | A new capability. Transcript cleanup, vocabulary bias, history browser each land as a MINOR. |
| PATCH | Fixes and internal changes with no user-visible behaviour change. |

Pre-1.0, MINOR is allowed to break things. `1.0.0` is the first version worth handing to
someone else.

## Milestone targets

Mapping the build order in the design spec onto versions:

| Version | Contents |
|---|---|
| `0.1.0` | Core loop — hotkey, recording, WhisperKit, paste, island states, menu bar, launch at login |
| `0.2.0` | Transcript cleanup via Foundation Models |
| `0.3.0` | Custom vocabulary bias |
| `0.4.0` | Transcript history |
| `1.0.0` | The above, stable in daily use, permissions flow polished |

## Tagging

Tags are annotated, never lightweight, so they carry a date and message:

```sh
git tag -a v0.1.0 -m "Core dictation loop"
git tag -n9              # list tags with messages
git describe --tags      # current version, with commits-since if dirty
```

Tag names are prefixed `v`. The version inside `CHANGELOG.md` is not.

## Release checklist

1. Move the `[Unreleased]` entries in `CHANGELOG.md` under a new version heading with the
   date.
2. Update `MARKETING_VERSION` in the Xcode project to match.
3. Commit as `chore: release vX.Y.Z`.
4. Tag the release commit with an annotated tag.
5. Open a fresh `[Unreleased]` section.

## Branches

`main` holds releasable work. Feature work happens on `feat/<slug>` branches and merges
back when the milestone is complete. No commits directly to `main` once `0.1.0` is tagged.
