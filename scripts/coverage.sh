#!/usr/bin/env bash
# Coverage per layer, not one global number. Domain and Application are pure, so
# full coverage is reachable and means something; adapters would only get there
# through mocks of Apple frameworks, which test the mock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

GLOBAL_FLOOR=90

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

read -r total covered < <(
  jq -e -r '
    [.data[0].files[] | select(.filename | contains("/Sources/"))]
    | select(length > 0)
    | "\(map(.summary.lines.count) | add) \(map(.summary.lines.covered) | add)"
  ' "$report"
)
percent=$((covered * 100 / total))
echo "Sources overall: $covered/$total lines (${percent}%, floor ${GLOBAL_FLOOR}%)"
echo "Adapters carry no line target, and Sources/listten is not measured at all."

if [[ "$percent" -lt "$GLOBAL_FLOOR" ]]; then
  echo "coverage: overall ${percent}% is below the ${GLOBAL_FLOOR}% floor" >&2
  failed=1
fi

exit "$failed"
