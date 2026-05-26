#!/usr/bin/env bash
# Compare zig statusline binary against the python reference for every fixture
# in tests/fixtures/. Time-until-reset segments inside [...] rate-limit blocks
# are normalized away because they advance with the wall clock between the two
# invocations and would otherwise flake.
#
# Usage: tests/parity.sh [path/to/zig/binary] [path/to/python/script]
#   defaults: zig-out/bin/statusline, ../statusline.py (parent dir)
#
# Exit 0 if every fixture matches; non-zero on first mismatch.

set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
zig_bin="${1:-$repo_root/zig-out/bin/statusline}"
py_script="${2:-$repo_root/../statusline.py}"
fixtures_dir="$repo_root/tests/fixtures"

if [[ ! -x "$zig_bin" ]]; then
    echo "parity: missing or non-executable zig binary at $zig_bin" >&2
    echo "        run 'zig build -Doptimize=ReleaseFast' first" >&2
    exit 2
fi
if [[ ! -f "$py_script" ]]; then
    echo "parity: python reference not found at $py_script" >&2
    exit 2
fi

# Strip the inner "(NhMMm)" / "(NdHHh)" / "(Nm)" / "(now)" segments that follow
# a percentage inside a rate-limit bracket; those are wall-clock-relative and
# differ between back-to-back invocations.
normalize() {
    # The pattern intentionally accepts both (Nm), (NhMMm), (NdHHh), (now),
    # surrounded by ANSI escape codes from C_DIM/C_RESET.
    sed -E 's/\(([0-9]+[smhd][0-9]*[smh]?|now)\)/(TIME)/g'
}

pass=0
fail=0
failed_names=()

shopt -s nullglob
fixtures=("$fixtures_dir"/*.json)
shopt -u nullglob
if [[ ${#fixtures[@]} -eq 0 ]]; then
    echo "parity: no fixtures found in $fixtures_dir" >&2
    exit 2
fi

for fx in "${fixtures[@]}"; do
    name="$(basename "$fx")"
    py_out="$("$py_script" < "$fx" 2>/dev/null || true)"
    if [[ -z "$py_out" ]]; then
        py_out="$(python3 "$py_script" < "$fx")"
    fi
    zig_out="$("$zig_bin" < "$fx")"

    py_norm="$(printf '%s' "$py_out" | normalize)"
    zig_norm="$(printf '%s' "$zig_out" | normalize)"

    if [[ "$py_norm" == "$zig_norm" ]]; then
        printf '  ok  %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL %s\n' "$name"
        printf '    --- python\n    +++ zig\n'
        diff <(printf '%s' "$py_norm") <(printf '%s' "$zig_norm") | sed 's/^/    /' || true
        fail=$((fail + 1))
        failed_names+=("$name")
    fi
done

echo
printf 'parity: %d passed, %d failed (of %d total)\n' "$pass" "$fail" "${#fixtures[@]}"
if [[ $fail -ne 0 ]]; then
    printf 'failed: %s\n' "${failed_names[*]}"
    exit 1
fi
