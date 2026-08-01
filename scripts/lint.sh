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

# grep exits 1 when it finds nothing and 2 on real errors. Only the first is fine.
search() {
  local out status
  out="$(grep "$@" || status=$?; exit ${status:-0})" || status=$?
  if [ "${status:-0}" -gt 1 ]; then
    echo "lint: grep failed on: $*" >&2
    exit 2
  fi
  printf '%s' "$out"
}

if [ -d Sources/ListtenCore/Domain ]; then
  bad="$(search -rn '^import ' Sources/ListtenCore/Domain --include='*.swift' | grep -vE 'import Foundation$' || true)"
  [ -n "$bad" ] && report "Domain may only import Foundation:
$bad"
fi

for dir in Sources/ListtenCore/Adapters/Capture Sources/ListtenCore/Adapters/Persistence; do
  [ -d "$dir" ] || continue
  bad="$(search -rn 'try?' "$dir" --include='*.swift')"
  [ -n "$bad" ] && report "'try?' is not allowed in $dir:
$bad"
done

bad="$(search -rn '^import ' Sources/listten --include='*.swift' | grep -vE 'import (Foundation|AppKit|SwiftUI|UserNotifications|ListtenCore)$' || true)"
[ -n "$bad" ] && report "unexpected import in the CLI target:
$bad"

if [ "$fail" -eq 0 ]; then
  echo "lint: ok"
fi
exit "$fail"
