#!/usr/bin/env bash
# Coverage per layer, not one global number. Domain and Application are pure, so
# full coverage is reachable and means something; adapters would only get there
# through mocks of Apple frameworks, which test the mock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if ! command -v jq >/dev/null 2>&1; then
  echo "coverage: jq is required to read the coverage report" >&2
  exit 1
fi

swift test --enable-code-coverage -Xswiftc -warnings-as-errors

report="$(swift test --show-codecov-path)"
if [[ ! -s "$report" ]]; then
  echo "coverage: no report at ${report:-<empty path>}" >&2
  exit 1
fi

# Sources/listten is absent from every figure below: the test target does not
# link the executable, so it is unmeasured rather than covered.
layer_lines() {
  jq -e -r --arg layer "$1" '
    [.data[0].files[] | select(.filename | contains("/Sources/ListtenCore/" + $layer + "/"))]
    | select(length > 0)
    | "\(map(.summary.lines.count) | add) \(map(.summary.lines.covered) | add)"
  ' "$report"
}

layer_gaps() {
  jq -r --arg layer "$1" '
    .data[0].files[]
    | select(.filename | contains("/Sources/ListtenCore/" + $layer + "/"))
    | select(.summary.lines.covered < .summary.lines.count)
    | "    \(.filename | split("/") | last): \(.summary.lines.count - .summary.lines.covered) line(s) uncovered"
  ' "$report"
}

failed=0

for layer in Domain Application; do
  # A layer that matches no file means the report or the directory moved. That
  # has to fail: a rule which measures nothing must never read as a pass.
  if ! read -r total covered < <(layer_lines "$layer"); then
    echo "coverage: no measured file under Sources/ListtenCore/$layer" >&2
    failed=1
    continue
  fi

  if [[ "$covered" -lt "$total" ]]; then
    echo "$layer: $covered/$total lines — needs 100%"
    layer_gaps "$layer"
    failed=1
  else
    echo "$layer: $covered/$total lines"
  fi
done

# Reported, never gated. Adapters are exercised against real devices and files,
# which CI has neither of. There is deliberately no overall percentage: with
# Domain and Application pinned at 100% and adapters excluded by policy, an
# overall figure only measures how much adapter code exists.
# Even here, where the number is a report rather than a gate, "nothing measured"
# has to be told apart from "nothing to measure".
adapter_sources="$(find Sources/ListtenCore/Adapters -name '*.swift' | wc -l | tr -d ' ')"
if read -r total covered < <(layer_lines Adapters); then
  echo "Adapters: $covered/$total lines, no target — covered by integration"
elif [[ "$adapter_sources" -gt 0 ]]; then
  echo "coverage: $adapter_sources adapter source(s) exist but none was measured" >&2
  failed=1
else
  echo "Adapters: no code yet"
fi

echo "Sources/listten is not measured: the test target does not link it."

exit "$failed"
