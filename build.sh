#!/bin/sh
# build both profiles and test on a posix host. the binary name has no .exe there.
set -e
cd "$(dirname "$0")"
mach build .
mach build . --profile release
mach test .
qark="./out/linux-x86_64/release/bin/qark"
if [ ! -x "$qark" ]; then
  qark="./out/darwin-x86_64/release/bin/qark"
fi
mkdir -p agent/reference
"$qark" --dump ops  > agent/reference/ops.txt
"$qark" --dump keys > agent/reference/keys.txt
"$qark" --dump lisp > agent/reference/lisp.txt
"$qark" --headless --stdio < agent/examples/smoke.ndjson
