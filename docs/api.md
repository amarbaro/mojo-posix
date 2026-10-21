# API

Everything here is asserted in `tests/api.mojo` or played by the nine scenarios in
`tools/oracle.py` against Python's `os`, `socket` and `select`. `from posix import ...`.

Errors raise `Error("posix: <call>: <strerror> (errno N)")`. Functions that cannot fail in a way
you would handle return `Bool` or a sentinel, as noted.

## Processes

| Call | Behaviour |
|---|---|
| `spawn(argv, env=[], cwd="", stdout="", stderr="", append=True, new_session=False) -> Int` | `posix_spawnp` of `argv[0]` (searched on this process's `PATH`); returns the pid. `env` is `NAME=value` strings; empty inherits the live environment, `setenv` changes included. `cwd` "" keeps ours. `stdout` and `stderr` are files created (mode 0666 minus umask) and appended to, or truncated when `append=False`; "" inherits ours; the same path for both shares one descriptor, so lines keep their order. `new_session=True` makes the child a session and group leader (pid == pgid), so `killpg(pid, ...)` reaches its whole tree. The child starts with no blocked signals and default handlers. A program that is not found, a missing `cwd` or an empty `argv` raises (`posix: spawn 'x': No such file or directory (errno 2)`). |
| `try_spawn(...) -> Tuple[Int, Int]` | `spawn` without the exception: `(pid, 0)`, or `(-1, errno)` when the program cannot start (2 not found, 13 not executable, 22 empty `argv`). |
| `reap(pid, block=False) -> Optional[Int]` | Collects a finished child: its exit code, or minus the signal number when a signal killed it (Popen's `returncode`). `None` while it still runs and `block=False`. A second call for the same child, or a pid that is not our child, raises `posix: waitpid: No child processes (errno 10)`. Restarts on `EINTR`. |
| `kill(pid, sig) -> Bool` | True when the signal was sent. Signal 0 only tests that the process exists. |
| `killpg(pgid, sig) -> Bool` | The same for every process in a group. |
| `exec(argv) -> Int` | `execvp`: replaces this process. Returns only on failure, with the errno (2 when the program is missing). |
| `getpid()`, `getppid()` | |
| `getpgid(pid) -> Int` | The process group of `pid` (0 is this process); -1 when there is no such process. |
| `environ() -> List[String]` | This process's environment as `NAME=value` strings. |

## Signals

| Call | Behaviour |
|---|---|
| `block_signals(sigs=[SIGINT, SIGTERM, SIGCHLD])` | Blocks the signals in every thread. The Mojo runtime starts one worker thread per CPU before `main()`, each with an empty mask, and the kernel may give a process-wide signal to any of them: SIGTERM then kills the program and SIGCHLD is lost. A mask survives `exec`, so when any thread has one of the signals open this blocks them here and re-runs the program through `/proc/self/exe` with the same arguments. Call it first in `main()`: everything before it runs twice. Returns at once when all threads already block them. Raises under `mojo run` (use `mojo build`). |
| `signal_fd(sigs=[SIGINT, SIGTERM, SIGCHLD]) -> Int32` | Blocks the signals in this thread and returns a non-blocking, close-on-exec descriptor that becomes readable when one arrives. Raises when the kernel refuses. |
| `read_signals(fd) -> List[Int]` | The signal numbers queued on a `signal_fd`, oldest first; empty when none. |

`SIGHUP SIGINT SIGKILL SIGUSR1 SIGUSR2 SIGTERM SIGCHLD SIGCONT SIGSTOP` are Linux x86-64 and
aarch64 numbers.

## PollSet

A set of descriptors for `poll(2)`, stored as packed `struct pollfd` records.

| Call | Behaviour |
|---|---|
| `add(fd, events=POLLIN) -> Int` | Adds a descriptor; returns its index. |
| `clear()`, `len(ps)` | Empties the set; counts its descriptors. |
| `wait(timeout_ms) -> Int` | The number of ready descriptors; 0 on timeout (-1 waits forever, 0 only checks); -1 when a signal interrupted it or on an error. An empty set sleeps for the timeout. |
| `revents(i) -> Int` | The events that fired on descriptor `i` at the last `wait`. |

`POLLIN POLLOUT POLLERR POLLHUP POLLNVAL`. A peer that closed shows `POLLHUP`.

## Unix sockets

| Call | Behaviour |
|---|---|
| `unix_listen(path) -> Int32` | A listening stream socket (backlog 128), non-blocking, close-on-exec, mode 0600. A file already at `path` is replaced. A path over 107 bytes, or a directory that is missing, raises. |
| `unix_connect(path) -> Int32` | A connected, blocking stream socket. No such file raises with errno 2; no listener with errno 111. |
| `accept(fd) -> Int32` | The next waiting connection (non-blocking, close-on-exec), or -1 when none waits. |
| `recv(fd, mut buf, block=False) -> Int` | Appends what the socket holds (up to 64 KiB) to `buf`. Returns the bytes added; 0 at end of stream; -1 when nothing is readable yet (`block=False`) or on an error. |
| `send_all(fd, data: Span[UInt8]) -> Bool` | Writes all of `data`. On a non-blocking socket it waits up to 5 s in all for room. False on an error or a closed peer; it never raises `SIGPIPE`. |
| `shutdown_write(fd)` | Half-close: the peer reads end of stream after the bytes already sent. |
| `close(fd)` | |

## Helpers

`cstr(s) -> List[UInt8]` is `s` plus a NUL, for a C `char *`. `errno() -> Int` is the calling
thread's errno.

## Behaviour the oracle pins down

- A child's exit status is `exit N` or a signal; `reap` reports the signal as -N.
- `killpg` on a `new_session` leader ends the leader and a grandchild it started.
- `reap(pid)` is non-blocking: a running child gives `None`, a reaped one raises `ECHILD`.
- A child's exit wakes a `poll` on a `signal_fd` for SIGCHLD.
- A `poll` with a timeout waits at least that long, and returns 0.
- 78,000 bytes cross a unix socket in partial sends and receives and arrive identical; the
  receiver sees end of stream after `shutdown_write`.
- Connecting to a path nobody bound gives errno 2.
