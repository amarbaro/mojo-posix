"""Oracle: each scenario run with Python's os/subprocess/signal/socket, printing
normalised lines. tests/cases.mojo (the library under test) prints the same lines
for the same scenario name; scripts/check.sh diffs the two.

Usage: oracle.py SCENARIO WORKDIR    (WORKDIR is an empty scratch directory)
"""
import os, select, signal, socket, subprocess, sys, time

def spawn(argv, cwd=None, env=None, out=None, append=False, new_group=False):
    """fork + exec with the child-side steps posix_spawn file actions perform."""
    fd = None
    if out:
        fd = os.open(out, os.O_WRONLY | os.O_CREAT | (os.O_APPEND if append else os.O_TRUNC), 0o644)
    pid = os.fork()
    if pid == 0:
        try:
            if new_group: os.setpgid(0, 0)
            if fd is not None: os.dup2(fd, 1); os.dup2(fd, 2)
            if cwd: os.chdir(cwd)
            os.execvpe(argv[0], argv, env if env is not None else os.environ)
        finally:
            os._exit(127)
    if fd is not None: os.close(fd)
    return pid

def status(st):
    if os.WIFEXITED(st): return "exit %d" % os.WEXITSTATUS(st)
    if os.WIFSIGNALED(st): return "signal %d" % os.WTERMSIG(st)
    return "other"

def case_spawn_cwd_env_log(w):
    log = os.path.join(w, "job.log"); os.mkdir(os.path.join(w, "run"))
    pid = spawn(["sh", "-c", 'pwd; echo "FOO=$FOO HOME=${HOME:-unset}"; echo err >&2; exit 3'],
                cwd=os.path.join(w, "run"), env={"FOO": "bar", "PATH": "/usr/bin:/bin"}, out=log)
    _, st = os.waitpid(pid, 0)
    print(status(st)); print(open(log).read().replace(w, "<W>"), end="")

def case_log_append(w):
    log = os.path.join(w, "a.log")
    for word in ("one", "two"):
        _, st = os.waitpid(spawn(["sh", "-c", "echo " + word], out=log, append=True), 0)
        print(status(st))
    print(open(log).read(), end="")

def case_exit_by_signal(w):
    _, st = os.waitpid(spawn(["sh", "-c", "kill -TERM $$"]), 0)
    print(status(st))

def case_process_group_kill(w):
    # leader runs a grandchild; killpg on the leader's group must end both
    pidf = os.path.join(w, "grandchild.pid")
    leader = spawn(["sh", "-c", "sleep 30 & echo $! > %s; wait" % pidf], new_group=True)
    for _ in range(200):
        if os.path.exists(pidf) and open(pidf).read().strip(): break
        time.sleep(0.01)
    gc = int(open(pidf).read())
    print("leader is group leader", os.getpgid(leader) == leader)
    print("grandchild in group", os.getpgid(gc) == leader)
    os.killpg(leader, signal.SIGTERM)
    _, st = os.waitpid(leader, 0); print("leader", status(st))
    for _ in range(200):
        try: os.kill(gc, 0); time.sleep(0.01)
        except ProcessLookupError: break
    alive = True
    try: os.kill(gc, 0)
    except ProcessLookupError: alive = False
    print("grandchild gone", not alive)

def case_waitpid_nohang(w):
    pid = spawn(["sh", "-c", "sleep 0.3"])
    r, _ = os.waitpid(pid, os.WNOHANG); print("running ->", "0" if r == 0 else "reaped")
    _, st = os.waitpid(pid, 0); print("after wait", status(st))
    try: os.waitpid(pid, os.WNOHANG); print("second reap ok")
    except ChildProcessError: print("second reap ECHILD")

def case_sigchld_wakes_poll(w):
    # SIGCHLD delivered as a readable fd (signalfd in the Mojo code; a self-pipe here)
    r, wfd = os.pipe(); os.set_blocking(wfd, False); signal.set_wakeup_fd(wfd); signal.signal(signal.SIGCHLD, lambda *_: None)
    pid = spawn(["sh", "-c", "exit 7"])
    p = select.poll(); p.register(r, select.POLLIN)
    ev = p.poll(5000); print("woken", bool(ev))
    _, st = os.waitpid(pid, 0); print(status(st))

def case_poll_timeout(w):
    r, _ = os.pipe(); p = select.poll(); p.register(r, select.POLLIN)
    t = time.monotonic(); ev = p.poll(100); dt = time.monotonic() - t
    print("events", len(ev)); print("waited >= 90 ms", dt >= 0.09); print("waited < 1 s", dt < 1.0)

def case_unix_socket_roundtrip(w):
    os.chdir(w); path = "s.sock"  # relative name: the scratch dir may exceed the 108-byte sun_path
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); srv.bind(path); srv.listen(4)
    cli = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); cli.connect(path)
    conn, _ = srv.accept()
    msg = b'{"op":"status","id":"j1"}\n' * 3000   # 78 KB: forces partial sends/recvs
    cli.sendall(msg); cli.shutdown(socket.SHUT_WR)
    got = b""
    while True:
        chunk = conn.recv(65536)
        if not chunk: break
        got += chunk
    print("bytes", len(got)); print("identical", got == msg)
    conn.sendall(b"ok\n"); conn.close(); print("reply", cli.recv(16).decode().strip())
    cli.close(); srv.close(); os.unlink(path); print("socket file removed", not os.path.exists(path))

def case_connect_refused(w):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    os.chdir(w)  # relative name, as in case_unix_socket_roundtrip
    try: s.connect("nobody.sock"); print("connected")
    except FileNotFoundError: print("ENOENT")
    except ConnectionRefusedError: print("ECONNREFUSED")

def popen_status(c): return "exit %d" % c if c >= 0 else "signal %d" % -c

def pair(argv):
    """The child's stdin and stdout are one end of a socketpair; ours is non-blocking."""
    a, b = socket.socketpair(); a.setblocking(False)
    p = subprocess.Popen(argv, stdin=b, stdout=b); b.close()
    return p, a

def case_spawn_pair_cat(w):
    # 3 MB through cat in 64 KB steps (the socket buffers are far smaller), then half-close
    p, a = pair(["cat"])
    msg = bytes(i % 251 for i in range(3 << 20)); got = bytearray(); off = 0
    while off < len(msg):
        r, wr, _ = select.select([a], [a], [])
        if r: got += a.recv(65536)
        if wr:
            try: off += a.send(msg[off:off + 65536])
            except BlockingIOError: pass
    a.shutdown(socket.SHUT_WR)
    while True:
        select.select([a], [], [])
        c = a.recv(65536)
        if not c: break
        got += c
    print("bytes", len(got)); print("identical", bytes(got) == msg)
    print(popen_status(p.wait()))
    a.close()

def case_spawn_pair_exits_at_once(w):
    p, a = pair(["true"])
    select.select([a], [], []); print("eof", a.recv(16) == b"")
    print(popen_status(p.wait()))
    try: a.send(b"x" * 4096); print("send ok")
    except BrokenPipeError: print("send EPIPE")
    a.close()

CASES = {k[5:]: v for k, v in globals().items() if k.startswith("case_")}
if __name__ == "__main__":
    if sys.argv[1] == "--list": print("\n".join(CASES)); sys.exit()
    CASES[sys.argv[1]](sys.argv[2])
