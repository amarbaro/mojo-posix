# Every behaviour docs/api.md states that tools/oracle.py scenarios do not already pin down.
from std.os import getenv, mkdir, setenv
from std.pathlib import Path, cwd
from std.testing import assert_equal, assert_true, assert_false
from posix import *


def run(sh: String, env: List[String] = [], stdout: String = "", stderr: String = "", append: Bool = True) raises -> Int:
    return reap(spawn(["sh", "-c", sh], env, stdout=stdout, stderr=stderr, append=append), True).value()


def test_spawn(dir: String) raises:
    # a program that does not exist, an empty argv, a missing cwd: all raise with the errno
    try:
        _ = spawn(["no-such-program-xyz"])
        assert_true(False, "spawn of a missing program must raise")
    except e:
        assert_equal(String(e), "posix: spawn 'no-such-program-xyz': No such file or directory (errno 2)")
    try:
        _ = spawn(["true"], cwd=dir + "/no/such/dir")
        assert_true(False, "spawn into a missing cwd must raise")
    except e:
        assert_true("errno 2)" in String(e))
    try:
        _ = spawn([])
        assert_true(False, "spawn of an empty argv must raise")
    except e:
        assert_equal(String(e), "posix: spawn: empty argv")
    var tried = try_spawn(["no-such-program-xyz"])
    assert_equal(tried[0], -1)
    assert_equal(tried[1], 2)
    assert_equal(try_spawn([])[1], 22)
    var ok = try_spawn(["true"])
    assert_true(ok[0] > 0 and ok[1] == 0)
    assert_equal(reap(ok[0], True).value(), 0)
    # exit codes and signals, as Popen.returncode
    assert_equal(run("exit 0"), 0)
    assert_equal(run("exit 42"), 42)
    assert_equal(run("kill -KILL $$"), -SIGKILL)
    # an empty env inherits ours; a given env replaces it
    var f = dir + "/env.txt"
    assert_equal(run('echo "$HOME"', stdout=f, append=False), 0)
    assert_equal(Path(f).read_text(), getenv("HOME") + "\n")
    _ = setenv("ZZ_LIVE", "yes")
    assert_equal(run('echo "$ZZ_LIVE"', stdout=f, append=False), 0)
    assert_equal(Path(f).read_text(), "yes\n", "inherits setenv changes made after start")
    var only: List[String] = ["ZZ=1"]
    assert_equal(run('echo "${ZZ-unset} ${HOME-unset}"', only, stdout=f, append=False), 0)
    assert_equal(Path(f).read_text(), "1 unset\n")
    # stdout/stderr: separate files, one shared file in order, truncate versus append
    var o = dir + "/o.txt"
    var er = dir + "/e.txt"
    assert_equal(run("echo out; echo err >&2", stdout=o, stderr=er), 0)
    assert_equal(Path(o).read_text(), "out\n")
    assert_equal(Path(er).read_text(), "err\n")
    assert_equal(run("echo a; echo b >&2; echo c", stdout=o, stderr=o, append=False), 0)
    assert_equal(Path(o).read_text(), "a\nb\nc\n")
    assert_equal(run("echo more", stdout=o, append=True), 0)
    assert_equal(Path(o).read_text(), "a\nb\nc\nmore\n")
    assert_equal(run("echo fresh", stdout=o, append=False), 0)
    assert_equal(Path(o).read_text(), "fresh\n")
    # a new session makes the child its own session and group leader
    var pid = spawn(["sh", "-c", "sleep 0.2"], new_session=True)
    assert_equal(getpgid(pid), pid)
    assert_equal(reap(pid, True).value(), 0)
    var same = spawn(["sh", "-c", "sleep 0.2"])
    assert_equal(getpgid(same), getpgid(0))
    assert_equal(reap(same, True).value(), 0)
    # the child starts with default signal handling and an empty mask, whatever we block
    block_signals([SIGUSR1])
    assert_equal(run("kill -USR1 $$"), -SIGUSR1)
    var env = environ()
    assert_true(len(env) > 0)
    var has_path = False
    for ref e in env:
        has_path = has_path or e.startswith("PATH=")
    assert_true(has_path)


def test_process() raises:
    assert_true(getpid() > 1)
    assert_true(getppid() > 0)
    assert_equal(getpgid(0), getpgid(getpid()))
    assert_equal(getpgid(2147483647), -1)
    var pid = spawn(["sh", "-c", "sleep 5"])
    assert_true(kill(pid, 0))
    assert_true(kill(pid, SIGTERM))
    assert_equal(reap(pid, True).value(), -SIGTERM)
    assert_false(kill(pid, 0), "a reaped pid is gone")
    assert_false(killpg(pid, SIGTERM), "no such group")
    var pid2 = spawn(["sh", "-c", "sleep 5"])
    assert_false(reap(pid2).__bool__(), "still running: None")
    _ = kill(pid2, SIGKILL)
    _ = reap(pid2, True)
    assert_equal(exec(["no-such-program-xyz"]), 2)


def test_signals() raises:
    block_signals([SIGUSR1, SIGUSR2])
    block_signals([SIGUSR1, SIGUSR2])  # blocked everywhere already: returns, no second exec
    var fd = signal_fd([SIGUSR1, SIGUSR2])
    assert_equal(len(read_signals(fd)), 0)
    assert_true(kill(getpid(), SIGUSR2))
    assert_true(kill(getpid(), SIGUSR1))
    var ps = PollSet()
    _ = ps.add(fd)
    assert_equal(ps.wait(1000), 1)
    var got = read_signals(fd)
    assert_equal(len(got), 2)
    assert_true(SIGUSR1 in got and SIGUSR2 in got)
    assert_equal(len(read_signals(fd)), 0)
    close(fd)


def test_poll(dir: String) raises:
    var ps = PollSet()
    assert_equal(len(ps), 0)
    assert_equal(ps.wait(0), 0, "an empty set times out")
    var srv = unix_listen(dir + "/poll.sock")
    var cli = unix_connect(dir + "/poll.sock")
    assert_equal(ps.add(srv), 0)
    assert_equal(ps.add(cli, POLLIN | POLLOUT), 1)
    assert_equal(len(ps), 2)
    assert_equal(ps.wait(1000), 2)
    assert_equal(ps.revents(0), POLLIN, "a connection is waiting")
    assert_equal(ps.revents(1), POLLOUT, "the client can write")
    var conn = accept(srv)
    ps.clear()
    assert_equal(len(ps), 0)
    _ = ps.add(conn)
    assert_equal(ps.wait(0), 0)
    close(cli)
    assert_equal(ps.wait(1000), 1)
    assert_true(ps.revents(0) & POLLHUP != 0, "the peer hung up")
    close(conn)
    close(srv)


def test_sockets(dir: String) raises:
    var path = dir + "/a.sock"
    Path(path).write_text("stale")
    var srv = unix_listen(path)  # replaces the stale file
    assert_equal(Int(Path(path).stat().st_mode) & 0o777, 0o600)
    assert_equal(accept(srv), -1, "nothing waiting")
    var long = dir + "/" + String("x") * 120
    try:
        _ = unix_listen(long)
        assert_true(False, "a path over 107 bytes must raise")
    except e:
        assert_true("longer than 107 bytes" in String(e))
    try:
        _ = unix_listen(dir + "/no/such/dir/s.sock")
        assert_true(False, "listen in a missing directory must raise")
    except e:
        assert_true(String(e).startswith("posix: bind '"))
    var cli = unix_connect(path)
    var conn = accept(srv)
    assert_true(conn >= 0)
    var buf = List[UInt8]()
    assert_equal(recv(conn, buf), -1, "nothing to read yet")
    assert_true(send_all(cli, "hello".as_bytes()))
    assert_equal(recv(conn, buf), 5)
    assert_true(send_all(cli, " world".as_bytes()))
    assert_equal(recv(conn, buf), 6)
    assert_equal(String(unsafe_from_utf8=Span(buf)), "hello world", "recv appends")
    assert_true(send_all(conn, "x".as_bytes()))
    var back = List[UInt8]()
    assert_equal(recv(cli, back, block=True), 1)
    shutdown_write(cli)
    assert_equal(recv(conn, buf), 0, "end of stream after shutdown_write")
    close(cli)
    assert_false(send_all(conn, "late".as_bytes()), "closed peer: False, no SIGPIPE")
    close(conn)
    close(srv)
    try:
        _ = unix_connect(path)
        assert_true(False, "nobody listens")
    except e:
        assert_true("errno 111)" in String(e), String(e))
    try:
        _ = unix_connect(dir + "/none.sock")
        assert_true(False, "no such socket")
    except e:
        assert_true("errno 2)" in String(e), String(e))
    try:
        _ = reap(2147483646)
        assert_true(False, "reap of a stranger must raise")
    except e:
        assert_equal(String(e), "posix: waitpid: No child processes (errno 10)")


def main() raises:
    block_signals([SIGUSR1, SIGUSR2])  # first, so the re-exec happens before any output
    var dir = String(".work/api")
    try:
        mkdir(".work")
    except:
        pass
    try:
        mkdir(dir)
    except:
        pass
    dir = String(cwd()) + "/" + dir
    test_spawn(dir)
    test_process()
    test_signals()
    test_poll(dir)
    test_sockets(dir)
    print("api: ok")
