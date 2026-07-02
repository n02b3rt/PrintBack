#!/usr/bin/env bash
# Builds and runs host-side unit tests for pure-logic modules in
# firmware/main/ (no ESP-IDF/hardware dependency, no board needed).
# Convention: test_X.c here tests firmware/main/X.c.
set -e
cd "$(dirname "$0")"
mkdir -p build

fail=0
for f in test_*.c; do
    name="${f%.c}"
    module="${name#test_}"
    src="../main/$module.c"

    if [ ! -f "$src" ]; then
        echo "skip $f: no matching $src"
        continue
    fi

    echo "=== building $name ==="
    gcc -std=c99 -Wall -Wextra -I../main "$f" "$src" -o "build/$name.exe" || { fail=1; continue; }

    echo "=== running $name ==="
    "./build/$name.exe" || fail=1
done

exit $fail
