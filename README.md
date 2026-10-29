# mojo-posix

[![CI](https://github.com/amarbaro/mojo-posix/actions/workflows/ci.yml/badge.svg)](https://github.com/amarbaro/mojo-posix/actions/workflows/ci.yml)

Processes, signals, `poll` and unix sockets for Mojo, straight to libc. Spawn a child with
its own cwd, environment, log files and process group; reap it without blocking; wait on
signals and sockets in one `poll`. Nine scenarios are checked against Python's `os`,
`socket` and `select`, and it keeps pace with them at about one megabyte less memory.

```mojo
from posix import block_signals, signal_fd, spawn, reap, PollSet, SIGCHLD

def main() raises:
    block_signals([SIGCHLD])                  # first: every thread must block what the signalfd reads
    var sigs = signal_fd([SIGCHLD])
    var pid = spawn(["sh", "-c", "exit 3"], cwd="/tmp", stdout="job.log")
    var ps = PollSet()
    _ = ps.add(sigs)
    while ps.wait(1000) <= 0:                 # sleeps until the child exits
        pass
    print(reap(pid, True).value())            # 3; minus N when signal N killed it
```

## Install

Requires Mojo 1.2 on Linux. The calls go straight to libc, so no linker flags.

| Way | Command |
|---|---|
| Source path | `mojo build -I path/to/mojo-posix/src app.mojo` |
| Precompiled | `mojo precompile src/posix -o posix.mojoc`, then put it next to your code |
| Vendor | copy `src/posix/` into your project |

## What you get

- `spawn(argv, env, cwd, stdout, stderr, append, new_session) -> pid`: `posix_spawnp` with a
  working directory, an environment, log files (one path for both streams shares a descriptor)
  and an optional new session so `killpg` reaches the whole tree.
- `try_spawn`: the same without the exception, `(pid, 0)` or `(-1, errno)`.
- `reap(pid, block)`: the exit code, or minus the signal number, as `Popen.returncode`.
- `kill`, `killpg`, `exec`, `getpid`, `getppid`, `getpgid`, `environ`.
- `block_signals`, `signal_fd`, `read_signals`: signals as a pollable descriptor, with the
  fix for the runtime's worker threads (below).
- `PollSet`: `add`, `wait`, `revents`, packed `pollfd` records.
- `unix_listen`, `unix_connect`, `accept`, `recv`, `send_all`, `shutdown_write`, `close`.
- Errors carry libc's message: `posix: spawn 'x': No such file or directory (errno 2)`.

The API is in [docs/api.md](docs/api.md). The memory and speed design is in
[docs/design.md](docs/design.md).

## Performance

`tests/bench.mojo` against `tools/bench_oracle.py` (`scripts/bench.sh`), three runs each, on a
machine with a load average near 20.

| | Python | mojo-posix |
|---|---|---|
| 1,000 spawn + reap of `/bin/true` | 305 to 317 ms, 12.7 to 12.8 MB | 316 to 317 ms, 11.5 to 11.7 MB |
| 256 MiB over a unix socket | 28 ms, 12.6 to 12.7 MB | 27 to 28 ms, 11.7 MB |
| 1,000,000 `poll(0)` calls | 472 to 482 ms, 12.4 to 12.7 MB | 404 to 416 ms, 11.6 MB |

Spawning is the kernel's `clone` and `exec` in both, so it ties. The memory difference is the
Python interpreter: an empty Mojo program uses 11.3 to 11.7 MB.

## Limits

- Linux only (x86-64 and aarch64 signal numbers); glibc's `posix_spawn` structure sizes.
- **Call `block_signals` first in `main()` if you read signals with `signal_fd`.** The runtime
  starts worker threads that take signals the main thread blocks: without it 14 of 100 SIGCHLD
  wakeups were lost and SIGTERM can kill the program. It re-runs the binary once, so code
  before it runs twice, and it raises under `mojo run`: build a binary.
- Unix stream sockets only; no TCP, `epoll`, `pipe` or `fork`.
- `env=[]` means inherit. To start a child with an empty environment pass one harmless
  variable.
- `send_all` on a non-blocking socket gives up after 5 s without room; the gate does not
  cover that path.
- `reap` is per child. There is no `waitpid(-1)`.
