#!/bin/bash
# Pre-commit hook to discourage HTML entity apostrophes in JSX files.
# Use {"'"} or wrap text in JSX expressions instead of &apos; or &#39;

set -euo pipefail

if [ "$#" -eq 0 ]; then
    echo "Usage: $0 <file1> [file2] ..."
    exit 0
fi

found=0
for file in "$@"; do
    if grep -n "&apos;\|&#39;" "$file" 2>/dev/null; then
        found=1
    fi
done

if [ "$found" -eq 1 ]; then
    echo ""
    echo "Error: Found HTML entity apostrophe (&apos; or &#39;)"
    echo "Use {\"'\"} or wrap the text in a JSX expression instead."
    exit 1
fi
