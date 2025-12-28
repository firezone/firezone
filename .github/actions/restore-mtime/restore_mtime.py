#!/usr/bin/env python3
"""
Restore file modification times from git history for better cache hits.

This script sets each tracked file's mtime to its last commit time,
enabling incremental build tools to correctly identify unchanged files.

Based on git-restore-mtime by MestreLion, simplified for CI use.
Requires full git history (fetch-depth: 0).
"""

import os
import subprocess
import sys


def main():
    # Get all tracked files and their last commit times in a single git log pass
    result = subprocess.run(
        ["git", "log", "--pretty=format:%H %ct", "--name-only", "--diff-filter=ACMRT"],
        capture_output=True,
        text=True,
        check=True,
    )

    seen = set()
    file_times = {}
    commit_time = None

    for line in result.stdout.splitlines():
        line = line.strip()
        if not line:
            continue

        # Check if this is a commit line (hash + timestamp)
        parts = line.split(" ", 1)
        if len(parts) == 2 and len(parts[0]) >= 40 and parts[1].isdigit():
            commit_time = int(parts[1])
            continue

        # This is a file path - record first occurrence (most recent commit)
        filepath = line
        if filepath not in seen and commit_time is not None:
            seen.add(filepath)
            file_times[filepath] = commit_time

    # Apply mtimes to existing files
    count = 0
    for filepath, timestamp in file_times.items():
        if os.path.isfile(filepath):
            try:
                os.utime(filepath, (timestamp, timestamp))
                count += 1
            except OSError:
                pass

    print(f"Restored mtime for {count} tracked files")


if __name__ == "__main__":
    main()
