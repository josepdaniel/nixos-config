#!/usr/bin/env bash
# claudix up: ensure a daemon is running for a project and print its ws URL.
#
#   up.sh [project-dir]        default: current directory
#
# Reuses a live daemon when one exists, otherwise starts one detached (its
# own session, so it outlives the shell and the Claude Code command that ran
# this). Prints one line: the WebSocket URL for the Monitor tool.
set -eu
project=$(cd "${1:-.}" && pwd -P)
here=$(cd "$(dirname "$0")" && pwd -P)
dir="${XDG_RUNTIME_DIR:-/tmp}/claudix"
mkdir -p "$dir"

ws_of() {   # prints ws url of a live daemon for $project, or nothing
  local f pid
  for f in "$dir"/*.json; do
    [ -f "$f" ] || continue
    if [ "$(jq -r .project "$f")" = "$project" ]; then
      pid=$(jq -r .pid "$f")
      if kill -0 "$pid" 2>/dev/null; then jq -r .ws "$f"; return 0; fi
      rm -f "$f"
    fi
  done
  return 1
}

if ws=$(ws_of); then echo "$ws"; exit 0; fi

log="$dir/$(echo -n "$project" | md5sum | cut -c1-12).log"
setsid nohup bun "$here/claudix.ts" --project "$project" > "$log" 2>&1 < /dev/null &

for _ in $(seq 1 40); do          # up to ~4s for the state file
  if ws=$(ws_of); then echo "$ws"; exit 0; fi
  sleep 0.1
done
echo "claudix: daemon did not start, see $log" >&2
exit 1
