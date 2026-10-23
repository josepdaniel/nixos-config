#!/usr/bin/env bash
# Exercises daemon/shim.ts across: no daemon, daemon started, killed, restarted.
set -u
cd "$(dirname "$0")/.."
P=${1:?scratch dir}
S=/run/user/1000/claudix/$(bun -e "console.log(Bun.hash(process.argv[1]).toString(36))" "$P/proj").json
printf 'fn main() {\n    let mut v = Vec::new();\n    loop {\n        v.push(1);\n    }\n}\n' > "$P/proj/main.rs"
(
  sleep 2;  bun daemon/claudix.ts --project "$P/proj" > "$P/d1.log" 2>&1 & 
  sleep 5;  kill "$(jq -r .pid "$S")"
  sleep 3;  bun daemon/claudix.ts --project "$P/proj" > "$P/d2.log" 2>&1 &
  sleep 7;  kill "$(jq -r .pid "$S")"
) &
timeline=$!
timeout 40 bun test/lsp-client.ts "$P/proj" main.rs \
  'status' 'wait:3500' \
  'comment:32:66:question:q1 before restart' 'hover:2:5' \
  'wait:5000' 'hover:2:5' \
  'wait:3000' 'comment:32:66:question:q2 after restart' 'hover:2:5' 2>&1 | grep -v '^<< initialize'
wait $timeline
