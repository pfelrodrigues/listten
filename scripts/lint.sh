#!/usr/bin/env bash
# Architecture rules from the design doc. A rule that is not enforced is a wish.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
fail=0

report() {
  echo "lint: $1" >&2
  fail=1
}

# 1. Domain must not depend on anything but Foundation.
if [ -d Sources/ListtenCore/Domain ]; then
  bad="$(grep -rn '^import ' Sources/ListtenCore/Domain --include='*.swift' \
    | grep -vE 'import Foundation$' || true)"
  [ -n "$bad" ] && report "Domain may only import Foundation:
$bad"
fi

# 2. No silent error discarding where losing a recording is unrecoverable.
for dir in Sources/ListtenCore/Adapters/Capture Sources/ListtenCore/Adapters/Persistence; do
  [ -d "$dir" ] || continue
  bad="$(grep -rn 'try?' "$dir" --include='*.swift' || true)"
  [ -n "$bad" ] && report "'try?' is not allowed in $dir:
$bad"
done

# 3. The CLI target must reach the domain only through ListtenCore.
bad="$(grep -rn '^import ' Sources/listten --include='*.swift' \
  | grep -vE 'import (Foundation|AppKit|SwiftUI|UserNotifications|ListtenCore)$' || true)"
[ -n "$bad" ] && report "unexpected import in the CLI target:
$bad"

if [ "$fail" -eq 0 ]; then
  echo "lint: ok"
fi
exit "$fail"
