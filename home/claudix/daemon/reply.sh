#!/usr/bin/env bash
# claudix reply: post a reply into a thread, tagged with this session's name.
#   reply.sh <port> <thread> <answered|applied|declined> <text>
set -eu
port=$1; thread=$2; status=$3; shift 3; text=$*
name=""
if [ -n "${CLAUDE_PID:-}" ]; then
  name=$(claude agents --json 2>/dev/null | jq -r --argjson p "$CLAUDE_PID" '.[] | select(.pid==$p) | .name' 2>/dev/null || true)
fi
[ -n "$name" ] || name=${CLAUDE_CODE_SESSION_ID:0:8}
curl -s -XPOST "localhost:$port/reply" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$thread" --arg x "$text" --arg s "$status" --arg f "$name" '{thread:$t,text:$x,status:$s,from:$f}')"
echo
