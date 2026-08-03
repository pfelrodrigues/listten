# Listten

Local meeting recorder for macOS. Captures the meeting, transcribes it on device
and writes markdown.

> Status: early development. Nothing is installable yet.

## Requirements

- macOS 26 or later, Apple Silicon
- Xcode (the Command Line Tools do not ship the test frameworks)

## Development

```sh
mise run check     # what CI runs: format, build, test with coverage, bundle
mise run test
mise run coverage  # test suite plus the per-layer coverage gate
mise run bundle    # assemble Listten.app
```

Without mise:

```sh
swift build
swift test
./scripts/bundle.sh
```

`swift run` is fine for the CLI, but notifications and permission grants need a
real bundle: `UNUserNotificationCenter` requires a bundle identifier, and TCC
ties grants to bundle identity. Use `scripts/bundle.sh` when testing those.

### Architecture rules

Five rules are enforced by the test suite rather than by convention:

- `Domain` imports nothing but `Foundation`
- `try?` is not allowed anywhere in `ListtenCore`
- the CLI reaches the domain only through `ListtenCore`
- every directory in the core is one of the four layers
- every port has an implementation outside the tests

Warnings are errors in CI, in the pre-push hook and in `mise run check`.

Coverage is gated per layer: `Domain` and `Application` at 100% of lines,
adapters reported but not gated, since they are covered by integration against
real devices and files.

`listten capture [seconds] [directory]` records from the microphone. Without a
directory it reports what arrived; with one it writes numbered CAF segments and
prints each as it closes. Either way it needs microphone permission, so it is a
manual check rather than a CI one.

```sh
mise run hooks     # enable the git hooks
```

## License

MIT
