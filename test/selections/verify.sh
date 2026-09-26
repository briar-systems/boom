#!/usr/bin/env bash
# every test declared under src runs under some `mach test` selection, on every target
#
# mach tests one artifact's closure (mach#3813), so a module no artifact
# reaches has its tests dropped without a word. this fails on any declared test
# that neither `mach test .` nor `mach test . --lib tests` collects, on each
# target named after the compiler, or every target the tests artifact declares.
# listing builds glfw's C step, so a target needs its C toolchain here.
set -euo pipefail

mach="${1:-mach}"
shift || true
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/boom-selections.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT

fail() { echo "FAIL: $1" >&2; exit 1; }

cd "$root"
# a test's qualified name is its module path, `#`, and its name: src/audio.mach's
# `test foo` is boom.audio#foo, which is what mach test --list prints first
project="$(sed -n 's/^id *= *"\(.*\)"$/\1/p' mach.toml)"
grep -rE --include='*.mach' '^[[:space:]]*test [A-Za-z_]' src \
    | sed -E "s|^src/(.*)\.mach:[[:space:]]*test ([A-Za-z_][A-Za-z0-9_]*).*|$project.\1#\2|; s|/|.|g" \
    | sort -u > "$scratch/declared.txt"
[ -s "$scratch/declared.txt" ] || fail "found no test declarations under src"

targets="$*"
[ -n "$targets" ] || targets="$(sed -n '/^\[artifact\.tests\]$/,/^\[/ s/^targets *= *\[\(.*\)\]$/\1/p' mach.toml | tr -d '"' | tr ',' ' ')"
[ -n "$targets" ] || fail "mach.toml declares no targets for the tests artifact"

list() {
    local out="$1"
    shift
    # the listing also carries the build's step lines; a test's qualified name holds `#`
    "$mach" test . "$@" --list > "$out.raw" || fail "could not list: mach test . $*"
    grep -E '^[^[:space:]]+#' "$out.raw" > "$out" || true
}

missing=0
for target in $targets; do
    list "$scratch/$target-boom.txt" --target "$target"
    list "$scratch/$target-tests.txt" --lib tests --target "$target"
    cat "$scratch/$target-boom.txt" "$scratch/$target-tests.txt" | awk '{print $1}' | sort -u > "$scratch/$target-union.txt"
    dropped="$(comm -23 "$scratch/declared.txt" "$scratch/$target-union.txt")"
    printf '%s: boom %d, tests %d, both %d of %d declared\n' "$target" \
        "$(wc -l < "$scratch/$target-boom.txt")" "$(wc -l < "$scratch/$target-tests.txt")" \
        "$(comm -12 "$scratch/declared.txt" "$scratch/$target-union.txt" | wc -l)" "$(wc -l < "$scratch/declared.txt")"
    if [ -n "$dropped" ]; then
        echo "::error::$target runs no selection that collects these tests; reach their modules from src/lib/tests.mach:"
        while IFS= read -r location; do printf '  %s\n' "$location"; done <<< "$dropped"
        missing=1
    fi
done

[ "$missing" = 0 ] || exit 1
echo "OK: every test declared under src runs under mach test . or mach test . --lib tests, on every target"
