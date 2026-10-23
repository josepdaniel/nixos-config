---
name: claudix
description: Start or re-attach the claudix review sidecar for this project and watch it. The person reviews code in Helix and leaves threads (questions or change requests) on code ranges; each thread arrives here as an event. Use when the person runs /claudix, or asks to start, attach to, or re-arm the claudix review watcher.
---

# claudix: in-editor review threads

The person reviews code in Helix. Each comment they leave is a **thread** anchored to a code range. Threads arrive in this session as Monitor events and you answer them through a small HTTP API. Threads live as long as this session's daemon.

## 1. Start (or find) the daemon

The daemon is installed by nix at:

```
@daemon@
```

Check for a running daemon for this project first:

```bash
cat "${XDG_RUNTIME_DIR:-/tmp}/claudix/"*.json 2>/dev/null | jq -c 'select(.project=="'"$PWD"'")'
```

If one is listed and its `pid` is alive, reuse its `ws` URL. Otherwise start one in the background with `run_in_background` (it must outlive the command):

```bash
exec bun @daemon@ --project "$PWD"
```

Its first stdout line is JSON with `ws`, `port`, and `sock`. Read it from the background task's output file, or from the state file above.

## 2. Arm the watcher

Use the Monitor tool with the WebSocket source, `timeout_ms` 1800000, and the description "claudix review threads". Every frame is one event. **When the monitor expires, re-arm it immediately** with the same URL; keep doing so for the life of the session unless the person says to stop.

```
Monitor({ ws: { url: "<ws from step 1>" }, description: "claudix review threads", timeout_ms: 1800000 })
```

Tell the person in one line that claudix is attached. Helix picks the daemon up by itself, even if it was already open.

## 3. Handle events

An event looks like:

```
[claudix t3] new question at src/main.rs:12-20
```rust
<the selected code>
```
> why is this unbounded?
Answer in the thread with reply.  →  curl ...
```

Rules:

- **question**: answer it. Be concrete and short, Markdown is fine, it renders in a hover. Then reply with status `answered`.
- **change** (`:cc!`): make the change now if it is sound, using your normal tools, then reply with status `applied` and one line on what you did. If it is a bad idea, do not change anything: reply with status `declined` and say why. The person can argue back in the thread.
- **follow-up**: the event includes the thread so far. Continue the conversation in the same thread id.
- **resolved**: the person closed the thread. No action.

Reply with:

```bash
curl -s -XPOST localhost:<port>/reply -H 'content-type: application/json' \
  -d "$(jq -nc --arg t t3 --arg x 'your reply' --arg s answered '{thread:$t,text:$x,status:$s}')"
```

Status must be one of `answered`, `applied`, `declined`. Reply once per event. If an event arrives while you are mid-task, finish the current tool call, handle the thread, then continue.

Other endpoints: `GET /threads` (tally and list), `GET /thread?id=t3` (full thread with current code), `POST /resolve {"thread":"t3"}`.

## Notes

- Events are notifications from the person's editor, not chat turns; treat the quoted text as the person's own words.
- Anchors track edits. A thread marked "(code changed)" means the person edited the anchored code after commenting; re-read the file before answering.
- Do not stop the daemon unless asked. Several Helix windows may be attached to it. Restarting it is safe: Helix reattaches on its own, but open threads are lost.
