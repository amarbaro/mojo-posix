# The Mojo side of tools/oracle.py: `cases SCENARIO WORKDIR` prints the same lines the oracle prints.
from std.os import mkdir, remove
from std.os.path import exists
from std.pathlib import Path
from std.sys import argv
from std.time import sleep, perf_counter
from posix import (
    spawn, reap, kill, killpg, getpgid, block_signals, signal_fd, PollSet, SIGTERM, SIGCHLD,
    unix_listen, unix_connect, accept, recv, send_all, shutdown_write, close,
)


def status(code: Int) -> String:
    return String("exit ", code) if code >= 0 else String("signal ", -code)


def finish(pid: Int) raises -> String:
    return status(reap(pid, True).value())


def spawn_cwd_env_log(w: String) raises:
    var log = w + "/job.log"
    mkdir(w + "/run")
    var env: List[String] = ["FOO=bar", "PATH=/usr/bin:/bin"]
    var sh = 'pwd; echo "FOO=$FOO HOME=${HOME:-unset}"; echo err >&2; exit 3'
    var pid = spawn(["sh", "-c", sh], env, cwd=w + "/run", stdout=log, stderr=log, append=False)
    print(finish(pid))
    print(Path(log).read_text().replace(w, "<W>"), end="")


def log_append(w: String) raises:
    var log = w + "/a.log"
    for word in ["one", "two"]:
        print(finish(spawn(["sh", "-c", "echo " + word], stdout=log)))
    print(Path(log).read_text(), end="")


def exit_by_signal(w: String) raises:
    print(finish(spawn(["sh", "-c", "kill -TERM $$"])))


def process_group_kill(w: String) raises:
    var pidf = w + "/grandchild.pid"
    var leader = spawn(["sh", "-c", "sleep 30 & echo $! > " + pidf + "; wait"], new_session=True)
    for _ in range(200):
        if exists(pidf) and Path(pidf).read_text().strip().byte_length() > 0:
            break
        sleep(0.01)
    var gc = atol(Path(pidf).read_text().strip())
    print("leader is group leader", getpgid(leader) == leader)
    print("grandchild in group", getpgid(gc) == leader)
    _ = killpg(leader, SIGTERM)
    print("leader", finish(leader))
    for _ in range(200):
        if not kill(gc, 0):
            break
        sleep(0.01)
    print("grandchild gone", not kill(gc, 0))


def waitpid_nohang(w: String) raises:
    var pid = spawn(["sh", "-c", "sleep 0.3"])
    print("running ->", "0" if not reap(pid) else "reaped")
    print("after wait", finish(pid))
    try:
        _ = reap(pid)
        print("second reap ok")
    except e:
        print("second reap", "ECHILD" if "No child processes" in String(e) else String(e))


def sigchld_wakes_poll(w: String) raises:
    block_signals([SIGCHLD])
    var sfd = signal_fd([SIGCHLD])
    var pid = spawn(["sh", "-c", "exit 7"])
    var ps = PollSet()
    _ = ps.add(sfd)
    print("woken", ps.wait(5000) > 0)
    print(finish(pid))


def poll_timeout(w: String) raises:
    var ps = PollSet()
    _ = ps.add(unix_listen(w + "/p.sock"))  # readable only when someone connects
    var t = perf_counter()
    var n = ps.wait(100)
    var dt = perf_counter() - t
    print("events", n)
    print("waited >= 90 ms", dt >= 0.09)
    print("waited < 1 s", dt < 1.0)


def unix_socket_roundtrip(w: String) raises:
    var path = w + "/s.sock"
    var srv = unix_listen(path)
    var cli = unix_connect(path)
    var conn = accept(srv)
    var msg = String('{"op":"status","id":"j1"}\n') * 3000  # 78 KB: forces partial sends and recvs
    _ = send_all(cli, msg.as_bytes())
    shutdown_write(cli)
    var got = List[UInt8]()
    var ps = PollSet()
    _ = ps.add(conn)
    while True:
        var n = recv(conn, got)
        if n == 0:
            break
        if n < 0:
            _ = ps.wait(1000)
    print("bytes", len(got))
    print("identical", String(unsafe_from_utf8=Span(got)) == msg)
    _ = send_all(conn, "ok\n".as_bytes())
    close(conn)
    var reply = List[UInt8]()
    _ = recv(cli, reply, block=True)
    print("reply", String(unsafe_from_utf8=Span(reply)).strip())
    close(cli)
    close(srv)
    remove(path)
    print("socket file removed", not exists(path))


def connect_refused(w: String) raises:
    try:
        _ = unix_connect(w + "/nobody.sock")
        print("connected")
    except e:
        var m = String(e)
        print("ENOENT" if "errno 2)" in m else ("ECONNREFUSED" if "errno 111)" in m else m))


def main() raises:
    var name = argv()[1]
    var w = String(argv()[2])
    if name == "spawn_cwd_env_log": spawn_cwd_env_log(w)
    elif name == "log_append": log_append(w)
    elif name == "exit_by_signal": exit_by_signal(w)
    elif name == "process_group_kill": process_group_kill(w)
    elif name == "waitpid_nohang": waitpid_nohang(w)
    elif name == "sigchld_wakes_poll": sigchld_wakes_poll(w)
    elif name == "poll_timeout": poll_timeout(w)
    elif name == "unix_socket_roundtrip": unix_socket_roundtrip(w)
    elif name == "connect_refused": connect_refused(w)
    else: raise Error("unknown scenario ", name)
