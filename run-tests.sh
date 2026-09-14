#!/usr/bin/env sh
# Runs the bundle through the mock PrusaSlicer API. Needs lua5.4 (or lua 5.4 as `lua`).
set -eu
cd "$(dirname "$0")"
LUA=${LUA:-$(command -v lua5.4 || command -v lua)}
BUNDLE=com.ripleydynamics.filament-dialin
for f in $(find "$BUNDLE" -name '*.lua' | sort); do
    "$LUA" -e "assert(loadfile('$f'))" || { echo "syntax error in $f"; exit 1; }
done
python3 -m unittest discover -s test -p 'test_*.py' || exit 1
exec "$LUA" test/run_tests.lua "$BUNDLE" $(find "$BUNDLE" -name '*.lua' | sort)
