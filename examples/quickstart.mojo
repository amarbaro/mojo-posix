# Run a command, wake on SIGCHLD through a signalfd, collect its exit code.
from std.os import mkdir
from std.pathlib import Path
from posix import block_signals, signal_fd, spawn, reap, PollSet, SIGCHLD


def main() raises:
    block_signals([SIGCHLD])  # first in main(): every thread must block what the signalfd reads
    try:
        mkdir(".work")
    except:
        pass
    var sigs = signal_fd([SIGCHLD])
    var pid = spawn(["sh", "-c", "echo hello from $PWD; exit 3"], stdout=".work/quick.log", append=False)
    var ps = PollSet()
    _ = ps.add(sigs)
    while not ps.wait(1000) > 0:
        pass
    print("exit code", reap(pid, True).value())
    print(Path(".work/quick.log").read_text(), end="")
