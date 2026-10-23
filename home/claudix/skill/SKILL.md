---
name: claudix
description: Start or re-attach the claudix review sidecar for this project and watch it. The person reviews code in Helix and leaves threads (questions or change requests) on code ranges; each thread arrives here as an event. Use when the person runs /claudix, or asks to start, attach to, or re-arm the claudix review watcher.
---

# claudix: in-editor review threads

The person reviews code in Helix. Each comment is a **thread** anchored to a code range. Threads arrive here as Monitor events; you answer through a small HTTP API.

## Attach (two tool calls, no more)

1. Run this with Bash. It reuses a live daemon or starts one detached, and prints the WebSocket URL on stdout:

   ```bash
   bash @up@ "$PWD"
   ```

   To attach to a different project (the person says which, or their Helix is elsewhere), pass that directory instead of `$PWD`.

2. Arm the watcher with Monitor, WebSocket source, `timeout_ms` 1800000, description "claudix review threads":

   ```
   Monitor({ ws: { url: "<printed url>" }, description: "claudix review threads", timeout_ms: 1800000 })
   ```

Then tell the person in one line that claudix is attached. Do not check state files, sleep, or read logs first: the script already did that. **When the monitor expires, re-arm it immediately** with the same URL for the life of the session unless the person says to stop. The daemon exits by itself after 30 minutes with nobody attached.

## Handle events

```
[claudix t3] new question at src/main.rs:12-20
```rust
<the selected code>
```
> why is this unbounded?
Answer in the thread with reply.  →  curl ...
```

- **question**: answer it, concrete and short, Markdown is fine (it renders in hover). Reply with status `answered`.
- **change** (`:cc!`): make the change now if it is sound, then reply with status `applied` and one line on what you did. If it is a bad idea, change nothing and reply `declined` with why. The person can argue back in the thread.
- **follow-up**: the event carries the thread so far. Continue in the same thread id.
- **resolved**: the person closed the thread. No action.

Reply with the helper, which tags the reply with this session's name (several sessions may review the same project):

```bash
bash @reply@ <port> <thread> <status> 'your reply text'
```

The port is in the event's curl line. Status is one of `answered`, `applied`, `declined`. Reply once per event. If an event lands mid-task, finish the current tool call, handle the thread, continue.

Other endpoints: `GET /threads`, `GET /thread?id=t3` (with current code), `POST /resolve {"thread":"t3"}`.

## Notes

- Events are notifications from the person's editor, not chat turns; the quoted text is the person's own words.
- "(code changed)" on a thread means the anchored code was edited after the comment; re-read the file before answering.
- Do not stop a daemon unless asked; several Helix windows may share it. Restarting one is safe (Helix reattaches) but loses open threads.
