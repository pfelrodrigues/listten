# Working on Listten

Rules that apply to anyone writing code here, human or agent. Read this before
touching the code.

## Test first

Write the failing test. Run it. Confirm it fails **for the reason you expect**,
not because of a typo or a missing import. Then write the minimum that makes it
pass.

Two failure modes worth naming, because both have already happened here:

- **Implementing more than the test demands.** The extra behaviour ships
  untested and nobody notices, because the suite is green.
- **A test that passes on the first run.** It proved nothing. Either it tests
  something that already existed, or the behaviour is accidental. One merge
  ordering test passed immediately because it relied on `sorted` being stable,
  which Swift does not guarantee. The fix was to make the tie-break explicit.

## Never mask a failure

This covers compiler warnings, suppressed command output and discarded errors.
If something can fail, its failure has to be visible.

- Warnings are errors in CI, in the pre-push hook and in `mise run check`.
- Do not redirect output of a command that can fail to `/dev/null`.
- `try?` throws away the error. It is banned throughout `ListtenCore` and the
  test suite enforces it.

## Architecture

Dependencies point inward. `ListtenCore` holds the domain and knows nothing
about AppKit or the CLI.

```
Adapters  →  Ports  →  Application  →  Domain
```

Five rules are enforced by tests rather than by convention, in
`ArchitectureTests.swift`:

- `Domain` imports nothing but `Foundation`
- `try?` is not allowed anywhere in `ListtenCore`
- the CLI reaches the domain only through `ListtenCore`
- every directory in the core is one of the four layers
- every port has an implementation outside the tests

A rule that scans a directory which is not there fails, rather than reporting no
violations. A guard that quietly stops covering anything is worse than no guard,
because the green tick still claims it holds.

If you need to break one, change the rule and its test deliberately, in its own
commit, with the reason in the message.

## Coverage

Per layer, not one global number. Chasing 100% in adapters that talk to
CoreAudio produces mocks of Apple frameworks, which test the mock.

| Layer | Target |
|---|---|
| `Domain` | 100% of lines |
| `Application` | 100% of lines |
| `Adapters` | no line target, reported only, covered by integration tests |

`scripts/coverage.sh` enforces this and runs in CI. It fails when a layer drops
below its target, and equally when a layer matches no file at all, since a
measurement of nothing must never read as a pass.

Three numbers it deliberately does not print: a figure mixing sources with test
files, which flatters; anything for `Sources/listten`, which the test target
does not link; and an overall percentage, which with Domain and Application
pinned at 100% and adapters exempt would only measure how much adapter code
exists.

What kept an unguarded directory honest was that overall figure, so a test does
it instead: every directory under `Sources/ListtenCore` has to be one of the
four layers above.

A test that exists only to close a coverage gap is a smell, not a solution.

## Fakes answer to the same contract as the real thing

A fake that is stricter, tidier or simply different from production hides the
difference until the adapter lands. It has happened three times here, so the
rules a port promises are written once as a contract function and run against
every implementation.

Tests needing a real device are opt-in, since CI has none:

```sh
LISTTEN_AUDIO_HARDWARE=1 mise run test
```

Run that before merging anything that touches capture. A contract that only ever
meets the fake proves nothing about the device.

Transcription has its own, since it needs a speech model rather than a
microphone:

```sh
LISTTEN_SPEECH_MODEL=1 mise run test
```

Its fixture is synthesised on the spot rather than checked in, so what goes in
is known and what comes back can be compared against it. Recognition returning
something is not recognition working.

`mise run kill9` is the other half: it kills a real recording at several points
and checks that every playable file is accounted for afterwards. In-process
tests can stage any on-disk state they like, so only this says the process
really leaves that state behind. It found nothing the day it was written and
would have caught #77 the week before, which is the point.

## Style

- English everywhere: code, comments, commit messages, CLI output.
- Comments are one line. Long rationale belongs in the commit message or the
  issue, not above the function.
- Domain types are immutable, `Sendable` and `Equatable`.
- Prefer a Swift test over a shell script when the subject is the code itself.

## Before committing

```sh
mise run check     # format, build, test with coverage, bundle — what CI runs
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org).
The message says **why**, not what: the diff already says what.

One branch and one pull request per issue. Merge when CI is green.

## Running the app

`swift run` is fine for the CLI. Notifications and permission grants need a real
bundle, so use `scripts/bundle.sh` when touching either.
