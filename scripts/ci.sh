#!/usr/bin/env bash
# CI entry point, same on a GitHub runner and a local Ubuntu VM: install, build, then every gate.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v uv >/dev/null || { echo "FAIL setup: uv not installed"; exit 1; }
uv sync || { echo "FAIL setup: uv sync"; exit 1; }
python3 -c 'import platform; print("oracle python", platform.python_version())'
mkdir -p .work/t
M=.venv/bin/mojo
for t in tests/cases:.work/cases tests/api:.work/t/api examples/quickstart:.work/t/quickstart; do
  $M build -I src "${t%%:*}.mojo" -o "${t##*:}" 2>.work/build.err || { echo "FAIL build: ${t%%:*}.mojo"; cat .work/build.err; exit 1; }
done
rm -rf .work/api
CASES=.work/cases scripts/check.sh
.work/t/api || { echo "FAIL api: tests/api.mojo"; exit 1; }
.work/t/quickstart > /dev/null || { echo "FAIL example: examples/quickstart.mojo"; exit 1; }
echo "PASS ci"
