#!/bin/bash
# Smoke test for the Vision OCR path: text is extracted in order, and an image
# with no text is reported as an error rather than silently copying nothing.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="${BIN:-.build/release/CopyText}"
failures=0

check() {
    if [ "$1" = "$2" ]; then
        echo "ok   - $3"
    else
        echo "FAIL - $3"
        echo "       expected: $1"
        echo "       actual:   $2"
        failures=$((failures + 1))
    fi
}

out=$("$BIN" --ocr test/fixture.png)
check "The quick brown fox jumps over the lazy dog." "$(echo "$out" | head -1)" "reads first line"
check "CopyText OCR test 12345" "$(echo "$out" | sed -n 2p)" "reads second line"
check 2 "$(echo "$out" | wc -l | tr -d ' ')" "preserves line count"

"$BIN" --ocr /tmp/blank.png >/dev/null 2>&1
check 1 "$?" "fails on an image with no text"

"$BIN" --ocr /tmp/does-not-exist.png >/dev/null 2>&1
check 1 "$?" "fails on a missing file"

if [ "$failures" -eq 0 ]; then echo "all checks passed"; else echo "$failures check(s) failed"; exit 1; fi
