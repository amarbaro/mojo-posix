---
name: mojo-posix
description: "Spawn processes, reap them, read signals and sockets from one poll, and talk over unix sockets from Mojo on Linux. Use when Mojo code must run a child with cwd/env/log files/process group, kill a process tree, wait on SIGCHLD or SIGTERM, or serve a unix socket."
---

# mojo-posix

POSIX processes, signals, `poll` and unix sockets for Mojo 1.2 on Linux, straight to libc.
Checked against Python's `os`, `socket` and `select`.

## Install

`mojo build -I <repo>/src app.mojo`, or `mojo precompile <repo>/src/posix -o posix.mojoc`, or
copy `src/posix/`.

## Use

```mojo
from posix import (block_signals, signal_fd, read_signals, spawn, reap, killpg, PollSet,
                   unix_listen, accept, recv, send_all, close, SIGTERM, SIGCHLD)

def main() raises:
    block_signals()                           # first line of main()
    var sigs = signal_fd()                    # SIGINT, SIGTERM, SIGCHLD
    var srv = unix_listen("/run/user/1000/app.sock")
    var pid = spawn(["sleep", "30"], new_session=True, stdout="out.log", stderr="out.log")
    var ps = PollSet()
    _ = ps.add(sigs)
    _ = ps.add(srv)
    while True:
        _ = ps.wait(1000)
        if ps.revents(0) != 0:
            for sig in read_signals(sigs):
                if sig == SIGTERM:
                    _ = killpg(pid, SIGTERM)
                    return
        if ps.revents(1) != 0:
            var c = accept(srv)               # -1 when nobody waits
            if c >= 0:
                _ = send_all(c, "hello\n".as_bytes())
                close(c)
        var code = reap(pid)                  # None while it runs
        if code:
            print("child exited", code.value())
```

## Rules

- `block_signals()` first in `main()` before `signal_fd`: the runtime's worker threads would
  otherwise take SIGTERM (kill) or SIGCHLD (lost). It re-runs the binary once; use a built
  binary, not `mojo run`.
- `reap(pid)` returns `None` while the child runs, the exit code after, minus N after signal
  N. Reap each child once: a second call raises `No child processes`.
- `spawn(env=[])` inherits. `new_session=True` makes pid == pgid: `killpg(pid, sig)` kills
  the tree. A missing program raises at `spawn`, not at `reap`.
- Sockets from `unix_listen` and `accept` are non-blocking: `accept` gives -1 when nobody
  waits, `recv` gives -1 when nothing arrived and 0 at end of stream. `recv` appends to your
  list; `clear()` it between calls to reuse the buffer.
- `send_all` takes a `Span[UInt8]`: pass `s.as_bytes()`. It returns False on a closed peer and
  never raises SIGPIPE.
- `PollSet.wait` returns -1 when a signal interrupted it: loop again.
- Declaring `read`, `write` or `poll` with other argument types in the same program fails the
  build with `existing function with conflicting signature`; match this library's
  (`Int` fds, `poll(Pointer, UInt64, Int32)`).
- Errors: `posix: connect '/x.sock': No such file or directory (errno 2)`.
