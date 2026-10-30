#!/usr/bin/env bash
# Builds the download for server owners: dist/sw_tow-<version>.zip with one sw_tow/ folder that
# holds only what a server runs. Tests, tools and CI stay in the repository.
#   scripts/release.sh          tests, then the zip of the last commit
#   scripts/release.sh --notes  only print this version's CHANGELOG section (for the GitHub release)
# The zip is made from the last commit (git archive), never from uncommitted files.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"

version=$(sed -n "s/^version '\([0-9][0-9.]*\)'.*/\1/p" fxmanifest.lua)
if [ -z "$version" ]; then
    echo "No version '<x.y.z>' line in fxmanifest.lua" >&2
    exit 1
fi

# This version's CHANGELOG section, without its heading.
notes() {
    awk -v v="$version" '
        /^## / { if (found) exit; if (index($0, "## " v " ") == 1 || $0 == "## " v) { found = 1; next } }
        found { print }
    ' CHANGELOG.md
}

if [ "${1:-}" = "--notes" ]; then
    notes
    exit 0
fi

if [ -z "$(notes | tr -d '[:space:]')" ]; then
    echo "CHANGELOG.md has no section for $version" >&2
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "Note: uncommitted changes are not in the zip (it is built from the last commit)." >&2
fi

bash scripts/test.sh

# What a server needs. Everything the manifest loads is under these paths.
paths=(fxmanifest.lua config.lua LICENSE README.md CHANGELOG.md bridge client server shared data html locales)

mkdir -p dist
zip="dist/sw_tow-$version.zip"
rm -f "$zip"
git archive --format=zip --prefix=sw_tow/ -o "$zip" HEAD -- "${paths[@]}"

# Every require in the code must resolve to a file in the zip.
listing=$(git archive --format=tar HEAD -- "${paths[@]}" | tar -t)
missing=0
while read -r module; do
    file="${module//.//}.lua"
    if ! grep -qx "$file" <<<"$listing"; then
        echo "Missing from the zip: $file (required as '$module')" >&2
        missing=1
    fi
done < <(grep -rhoE "require[ (]*'[a-z_.]+'" bridge client server shared | grep -oE "'[a-z_.]+'" | tr -d "'" | grep -E '^(bridge|client|server|shared|data)\.' | sort -u)
[ "$missing" = 0 ] || { rm -f "$zip"; exit 1; }

count=$(grep -c . <<<"$listing" || true)
size=$(wc -c <"$zip" | tr -d ' ')
echo
echo "Built $zip: $count files, $((size / 1024)) KiB, from commit $(git rev-parse --short HEAD)"
