#!/bin/bash
# Apply the webOS overlay to a KOReader checkout. Safe to run repeatedly.
#
#   overlay/files/          new files, copied into the KOReader tree at the same relative path
#   overlay/transforms.py   the few edits to upstream files (idempotent, tolerant of upstream changes)
#
# Usage:  overlay/apply.sh [path-to-koreader]        (default: ~/koreader)
# Exit status is non-zero if an edit could not be made (upstream changed something we depend on).
set -e

KO=$(realpath "${1:-$HOME/koreader}")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
[ -f "$KO/reader.lua" ] || { echo "error: $KO does not look like a KOReader checkout"; exit 1; }

echo "== copying new files into $KO"
(cd "$HERE/files" && find . -type f | sort) | while read -r f; do
    mkdir -p "$KO/$(dirname "$f")"
    cp "$HERE/files/$f" "$KO/$f"
    echo "   $f"
done

echo "== editing upstream files"
python3 "$HERE/transforms.py" "$KO"
