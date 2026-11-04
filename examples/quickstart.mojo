from posix import block_signals, signal_fd, spawn, reap, PollSet, SIGCHLD


def main() raises:
    block_signals([SIGCHLD])  # first in main(): every thread must block what the signalfd reads
    var sigs = signal_fd([SIGCHLD])
    var pid = spawn(["sh", "-c", "echo hello; exit 3"])
    var ps = PollSet()
    _ = ps.add(sigs)
    _ = ps.wait(1000)  # wakes on SIGCHLD
    print("exit code", reap(pid, True).value())
