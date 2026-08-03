#!/bin/sh
# Example post-processing hook: copies the note into a folder of your choosing.
# The session directory arrives as $1 and as LISTTEN_SESSION_DIR; anything this
# prints goes to Listten's log, and whatever it does, the session stands.
set -eu

session="${1:-${LISTTEN_SESSION_DIR:?no session directory}}"
note="$session/note.md"
destination="${LISTTEN_HOOK_DESTINATION:-$HOME/Documents/Meetings}"

if [ ! -f "$note" ]; then
  echo "no note at $note" >&2
  exit 1
fi

mkdir -p "$destination"
cp "$note" "$destination/$(basename "$session").md"
echo "copied $note into $destination"
