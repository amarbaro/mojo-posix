#!/usr/bin/env bash
# The gate: every scenario in tools/oracle.py run by the Python oracle and by CASES
# (the Mojo case runner, built from tests/cases.mojo), outputs identical, each in a
# fresh scratch directory. Each scenario runs twice per side to catch flakiness.
set -euo pipefail
cd "$(dirname "$0")/.."
: "${CASES:?FAIL setup: set CASES to the built case runner}"
mkdir -p .work/check; fail=0; n=0
for c in $(python3 -I tools/oracle.py --list); do
  for run in 1 2; do
    for side in exp got; do
      w=$(mktemp -d "$PWD/.work/check/$c.$side.XXXX")
      if [ $side = exp ]; then python3 -I tools/oracle.py "$c" "$w" > .work/check/$c.$side 2>&1 || true
      else timeout 20 "$CASES" "$c" "$w" > .work/check/$c.$side 2>&1 || true; fi
      rm -rf "$w"
    done
    cmp -s .work/check/$c.exp .work/check/$c.got || { echo "FAIL $c (run $run)"; diff .work/check/$c.exp .work/check/$c.got | head -6; fail=$((fail+1)); }
  done
  n=$((n+1))
done
echo "scenarios: $n, each twice; failures: $fail"
[ "$fail" -eq 0 ] || { echo "FAIL check: $fail"; exit 1; }
echo "PASS all"
