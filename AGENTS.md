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

- Warnings are errors in CI and in the pre-push hook.
- Do not redirect output of a command that can fail to `/dev/null`.
- `try?` throws away the error. It is banned throughout `ListtenCore` and the
  test suite enforces it.

## Architecture

Dependencies point inward. `ListtenCore` holds the domain and knows nothing
about AppKit or the CLI.

```
Adapters  →  Ports  →  Application  →  Domain
```

Three rules are enforced by tests rather than by convention, in
`ArchitectureTests.swift`:

- `Domain` imports nothing but `Foundation`
- `try?` is not allowed anywhere in `ListtenCore`
- the CLI reaches the domain only through `ListtenCore`

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
| `Adapters` | no line target, covered by integration tests |

A test that exists only to close a coverage gap is a smell, not a solution.

## Style

- English everywhere: code, comments, commit messages, CLI output.
- Comments are one line. Long rationale belongs in the commit message or the
  issue, not above the function.
- Domain types are immutable, `Sendable` and `Equatable`.
- Prefer a Swift test over a shell script when the subject is the code itself.

## Before committing

```sh
mise run check     # format, build, test
```

Commits follow [Conventional Commits](https://www.conventionalcommits.org).
The message says **why**, not what: the diff already says what.

One branch and one pull request per issue. Merge when CI is green.

## Running the app

`swift run` is fine for the CLI. Notifications and permission grants need a real
bundle, so use `scripts/bundle.sh` when touching either.
