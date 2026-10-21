# Design

The calls go straight to libc: no wrapper layer, no linker flags. The decisions below each
had a measurement or a failure behind them.

## Memory

- **`spawn` allocates a constant number of buffers.** One zeroed block holds the
  `posix_spawn` file actions, the attributes and the signal set (80 + 336 + 128 bytes, glibc
  sizes). `argv` and `envp` are each one byte buffer holding all the strings plus one pointer
  array. The earlier code made one list per string and three separate state lists, so an
  environment of 60 variables cost 60 allocations. With no `env`, the child gets libc's live
  `environ` pointer: nothing is copied or read from `/proc`.
- **`recv` reads into the caller's buffer.** The earlier `recv_some` allocated and zeroed a
  64 KiB temporary on every call and copied it. `recv` grows the list, reads straight into the
  new tail and shrinks it to the bytes that arrived. A caller that clears the list between
  calls never reallocates.
- **`PollSet` is one `List[Int64]`.** A `struct pollfd` is 8 bytes (`fd:i32, events:i16,
  revents:i16`), so a record is one `Int64` and the list is handed to the kernel as is. No
  array of structs, no conversion.
- **`send_all` borrows its data** as a `Span[UInt8]`; nothing is copied.
- **No object per descriptor.** A socket is an `Int32`; the caller decides who closes it.

### Measurements

Same machine, three runs each, load average about 20 from other jobs (so only the ratios
are meaningful).

| Work | Python | mojo-posix |
|---|---|---|
| 1,000 x spawn `/bin/true` + reap | 305 to 317 ms, 12.7 to 12.8 MB | 316 to 317 ms, 11.5 to 11.7 MB |
| 256 MiB over a unix socket, 64 KiB chunks | 28 ms, 12.6 to 12.7 MB | 27 to 28 ms, 11.7 MB |
| 1,000,000 x `poll(0)` on 4 descriptors | 472 to 482 ms, 12.4 to 12.7 MB | 404 to 416 ms, 11.6 MB |

`spawn` is the kernel's `clone` + `exec`, which Python reaches too: parity is the floor. An
empty Mojo program uses 11.3 to 11.7 MB, so the memory difference is the Python interpreter.

Against the code it replaces (`libc.mojo` of gpu-wait, a 61-variable environment, 4,096 x
64 KiB):

| | before | after |
|---|---|---|
| 1,000 x spawn, user CPU | 0.25 s | 0.22 s |
| 4,096 x recv of 64 KiB | 33 to 36 ms, 12.3 MB | 26 to 27 ms, 11.6 MB |

## Signals and the runtime's threads

A `signalfd` only sees signals that no thread takes first. The runtime starts one worker
per CPU (17 on the build machine) before `main()`; each has an empty mask. Measured with the
scenario `sigchld_wakes_poll` on a binary that only calls `signal_fd`: 14 of 100 runs and 6 of 40
never woke (SIGCHLD went to a worker, whose default action discards it); with `block_signals`
first, 0 of 200. `block_signals` uses the one tool that reaches threads that already exist: a mask
survives `exec`, so it blocks the signals and re-runs the binary, and every thread of the
new process starts blocked. It reads `SigBlk` of each `/proc/self/task/*/status`, so it
needs no marker argument and stops after one re-run.

## `external_call` signatures

Two declarations of one libc symbol with different argument types do not link in one
program (`existing function with conflicting signature`). A library that shares a program
with others must agree with them and with the standard library: file descriptors for
`read`/`write` are `Int`, `poll` takes `(Pointer, UInt64, Int32)` as in mojo-inotify, and
`recv`/`send` take `Int(fd)` and a pointer. Buffers that C writes through two arguments of
one allocation (the spawn state block) go as `Int` addresses, because two mutable
`Pointer`s into one list are rejected as aliasing.

## What it leaves out

No `fork`, no `pipe`, no `epoll`, no TCP, no `select`: `spawn` plus files covers the daemons
this was extracted from, and `PollSet` covers waiting. See README for the limits.
