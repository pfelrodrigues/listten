#!/usr/bin/env bash
# Kills a real recording at several points and checks what recovery makes of
# what was left. In-process tests can stage any on-disk state they like; only
# this can say the process actually leaves that state behind.
#
# Needs a microphone and a granted permission, so it is manual rather than CI.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

WORK="${1:-$(mktemp -d)}"
ROTATION=3
FAILURES=0

swift build --product listten
LISTTEN="$ROOT/.build/debug/listten"

# Kills at instants that fall in different places relative to a 3 second
# rotation: before the first close, just after one, and inside a later segment.
for AT in 1 4 8; do
  CASE="$WORK/kill-at-${AT}s"
  rm -rf "$CASE"

  "$LISTTEN" record 60 "$CASE" "$ROTATION" >/dev/null 2>&1 &
  PID=$!
  sleep "$AT"
  kill -9 "$PID" 2>/dev/null || true
  wait "$PID" 2>/dev/null || true

  SESSION="$(find "$CASE" -maxdepth 1 -mindepth 1 -type d | head -1)"
  if [[ -z "$SESSION" ]]; then
    echo "kill at ${AT}s: no session directory was written" >&2
    FAILURES=$((FAILURES + 1))
    continue
  fi

  FILES=$(find "$SESSION/audio" -name '*.caf' 2>/dev/null | wc -l | tr -d ' ')
  BEFORE=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['state'])" \
    "$SESSION/session.json")

  RESUME_OUT="$("$LISTTEN" resume "$CASE" 2>&1)" || true
  AFTER=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['state'])" \
    "$SESSION/session.json")
  COUNTED=$(/usr/bin/python3 -c \
    "import json,sys;print(len(json.load(open(sys.argv[1]))['segments']))" \
    "$SESSION/session.json")

  echo "kill at ${AT}s: $FILES file(s) on disk, $BEFORE -> $AFTER, $COUNTED counted"

  # Every playable file has to be accounted for, including the one that was
  # open when the process died. That is the whole write-ahead claim.
  for FILE in "$SESSION"/audio/*.caf; do
    [[ -e "$FILE" ]] || continue
    if ! afinfo "$FILE" >/dev/null 2>&1; then
      echo "  $(basename "$FILE") is not playable" >&2
      FAILURES=$((FAILURES + 1))
    fi
  done

  if [[ "$AFTER" == "recording" ]]; then
    echo "  recovery left it recording: $RESUME_OUT" >&2
    FAILURES=$((FAILURES + 1))
  fi
  if [[ "$COUNTED" -ne "$FILES" ]]; then
    echo "  $FILES file(s) on disk but $COUNTED counted: $RESUME_OUT" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

echo
if [[ "$FAILURES" -eq 0 ]]; then
  echo "every kill left playable audio, and recovery accounted for all of it"
else
  echo "$FAILURES check(s) failed" >&2
fi
exit "$FAILURES"
