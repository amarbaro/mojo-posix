# Speed and memory: `bench MODE` with MODE spawn | stream | poll. The same work as tools/bench_oracle.py.
#   spawn   1,000 x (spawn /bin/true, reap)
#   stream  256 MiB over a unix socket in 64 KiB chunks (send, then recv)
#   poll    1,000,000 x poll(2) with timeout 0 on a 4-descriptor set
from std.sys import argv
from std.time import perf_counter_ns
from posix import spawn, reap, PollSet, unix_listen, unix_connect, accept, recv, send_all, close


def main() raises:
    var mode = argv()[1]
    var t0 = perf_counter_ns()
    var check = 0
    if mode == "spawn":
        for _ in range(1000):
            check += reap(spawn(["/bin/true"]), True).value()
    elif mode == "stream":
        var path = String(argv()[2])
        var srv = unix_listen(path)
        var cli = unix_connect(path)
        var conn = accept(srv)
        var chunk = List[UInt8](length=65536, fill=97)
        var got = List[UInt8]()
        for _ in range(4096):
            _ = send_all(cli, Span(chunk))
            got.clear()
            check += recv(conn, got)
        close(cli)
        close(conn)
        close(srv)
    else:
        var ps = PollSet()
        for _ in range(4):
            _ = ps.add(0)
        for _ in range(1000000):
            check += ps.wait(0)
    print(mode, "ms", Int(perf_counter_ns() - t0) // 1000000, "check", check)
