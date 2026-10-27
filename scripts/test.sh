#!/usr/bin/env bash
# Everything that runs without a server, in one go: the offline test suite (Lua 5.4) and the
# static analysis (scripts/check.sh). Exits non-zero when anything fails.
#   scripts/test.sh            all tests, then the analysis
#   scripts/test.sh impound    only tests whose name contains "impound", then the analysis
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

lua=""
for candidate in lua5.4 lua54 lua "${LOCALAPPDATA:-}/Programs/Lua/bin/lua.exe"; do
    if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -v 2>&1 | grep -q 'Lua 5\.4'; then
        lua=$candidate
        break
    fi
done
if [ -z "$lua" ]; then
    echo "Lua 5.4 not found. Windows: winget install DEVCOM.Lua · Debian/Ubuntu: apt install lua5.4 · macOS: brew install lua" >&2
    exit 2
fi

echo "== Offline tests"
"$lua" tests/run.lua "$@"
echo
echo "== Static analysis"
bash scripts/check.sh
