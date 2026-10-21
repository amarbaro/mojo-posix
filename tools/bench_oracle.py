"""Same work as tests/bench.mojo with Python's subprocess, socket and select. Usage: bench_oracle.py MODE [SOCKET_PATH]"""
import select, socket, subprocess, sys, time

mode = sys.argv[1]
t0 = time.perf_counter_ns()
check = 0
if mode == "spawn":
    for _ in range(1000):
        check += subprocess.Popen(["/bin/true"]).wait()
elif mode == "stream":
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(sys.argv[2]); srv.listen(128)
    cli = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); cli.connect(sys.argv[2])
    conn, _ = srv.accept(); conn.setblocking(False)
    chunk = b"a" * 65536
    got = bytearray(65536)
    for _ in range(4096):
        cli.sendall(chunk)
        check += conn.recv_into(got)
    cli.close(); conn.close(); srv.close()
else:
    p = select.poll()
    for _ in range(4):
        p.register(0, select.POLLIN)
    for _ in range(1000000):
        p.poll(0)
print(mode, "ms", (time.perf_counter_ns() - t0) // 1000000, "check", check)
