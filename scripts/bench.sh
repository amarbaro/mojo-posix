#!/usr/bin/env bash
# Mojo versus Python on the same work (tests/bench.mojo, tools/bench_oracle.py): 3 runs each,
# wall ms as the program prints it and peak RSS from /usr/bin/time.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .work/t
.venv/bin/mojo build -I src tests/bench.mojo -o .work/t/bench 2>.work/build.err || { echo "FAIL build: tests/bench.mojo"; cat .work/build.err; exit 1; }
for mode in spawn stream poll; do
  for run in 1 2 3; do
    for who in mojo python; do
      rm -f .work/bench.sock
      if [[ $who == mojo ]]; then cmd=(.work/t/bench "$mode" "$PWD/.work/bench.sock"); else cmd=(python3 -I tools/bench_oracle.py "$mode" "$PWD/.work/bench.sock"); fi
      out=$(/usr/bin/time -f "%M" "${cmd[@]}" 2>&1 </dev/null) || { echo "FAIL bench: $who $mode"; exit 1; }
      echo "$mode $who run$run: $(echo "$out" | head -1 | cut -d' ' -f3) ms, $(echo "$out" | tail -1) KB"
    done
  done
done
