#!/usr/bin/env bash
# Static analysis with lua-language-server: undefined globals and natives, wrong fields, argument
# counts, type mismatches. Fetches LuaLS, the CfxLua natives addon, ox_lib and qbx_core into
# .check/ on first run. Exits non-zero when anything is found.
#   scripts/check.sh            (Linux, macOS, Git Bash on Windows)
set -euo pipefail

LUALS_VERSION=3.13.9
OX_LIB_VERSION=v3.30.0
QBX_CORE_VERSION=v1.19.0

root=$(cd "$(dirname "$0")/.." && pwd)
# Git Bash: native Windows tools mis-convert POSIX paths with brackets, like resources/[shiftworks].
if command -v cygpath >/dev/null; then root=$(cygpath -m "$root"); fi
cache="$root/.check"
mkdir -p "$cache"

case "$(uname -s)" in
    Linux*) platform=linux-x64; archive=tar.gz; exe=lua-language-server ;;
    Darwin*) platform=darwin-arm64; archive=tar.gz; exe=lua-language-server ;;
    MINGW*|MSYS*|CYGWIN*) platform=win32-x64; archive=zip; exe=lua-language-server.exe ;;
    *) echo "Unsupported platform: $(uname -s)" >&2; exit 2 ;;
esac

luals="$cache/luals/bin/$exe"
if [ ! -x "$luals" ]; then
    url="https://github.com/LuaLS/lua-language-server/releases/download/$LUALS_VERSION/lua-language-server-$LUALS_VERSION-$platform.$archive"
    mkdir -p "$cache/luals"
    curl -fsSL "$url" -o "$cache/luals.$archive"
    if [ "$archive" = zip ]; then unzip -q -o "$cache/luals.$archive" -d "$cache/luals"; else tar -xzf "$cache/luals.$archive" -C "$cache/luals"; fi
    rm "$cache/luals.$archive"
fi

fetch() { # name, url, tag
    [ -d "$cache/$1" ] || git -c advice.detachedHead=false clone -q --depth 1 ${3:+--branch "$3"} "$2" "$cache/$1"
}
fetch addon https://github.com/overextended/fivem-lls-addon
fetch ox_lib https://github.com/overextended/ox_lib "$OX_LIB_VERSION"
fetch qbx_core https://github.com/Qbox-project/qbx_core "$QBX_CORE_VERSION"

work="$cache/work"
rm -rf "$work" && mkdir -p "$work/sw_tow"
cp -r "$root/bridge" "$root/client" "$root/server" "$root/shared" "$root/data" "$root/config.lua" "$root/fxmanifest.lua" "$work/sw_tow/"
cat > "$work/sw_tow/.luarc.json" <<JSON
{
  "runtime.version": "Lua 5.4",
  "runtime.plugin": "$cache/addon/plugin.lua",
  "runtime.nonstandardSymbol": ["/**/", "\`", "+=", "-=", "*=", "/=", "<<=", ">>=", "&=", "|=", "^="],
  "workspace.library": [
    "$cache/addon/library/runtime",
    "$cache/addon/library/natives/CFX-NATIVE",
    "$cache/addon/library/natives/GTAV",
    "$cache/ox_lib",
    "$cache/qbx_core"
  ],
  "workspace.checkThirdParty": false,
  "diagnostics.globals": ["lib", "cache", "locale", "qbx", "MySQL", "Config"]
}
JSON

cd "$work"
output=$("$luals" --check sw_tow --checklevel=Warning --logpath "$work/log" 2>&1 | tr '\r' '\n' | sed 's/\x1b\[[0-9;]*m//g') || true  # LuaLS exits non-zero when it finds problems
# One line per problem: file:line:col [level] message (progress output removed).
echo "$output" | grep -o -E 'sw_tow[\/][^ ]+\.lua:[0-9]+:[0-9]+ \[[A-Za-z]+\] .*|Diagnosis.*' || true
echo "$output" | grep -q 'no problems found'
