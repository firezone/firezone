#!/usr/bin/env python3
"""CI gate: assert the committed fuzz corpus keeps `tunnel-proto` region
coverage at or above a threshold.

Run AFTER `cargo fuzz coverage --fuzz-dir tests/fuzz tunnel`, which replays the
committed corpus (any crash fails there) and writes
`tests/fuzz/coverage/tunnel/coverage.profdata`, rebuilding the target in place
with `-Cinstrument-coverage`.

    python3 tests/fuzz/check_coverage.py <min_region_pct>

`llvm-cov` is resolved from the toolchain named by `$COVERAGE_TOOLCHAIN`
(default `nightly`) so it matches the toolchain that produced the profdata.
Exits non-zero if coverage is below the threshold or artifacts are missing.
Intended to run from the `rust/` directory.
"""
import json
import os
import subprocess
import sys

PROFDATA = "tests/fuzz/coverage/tunnel/coverage.profdata"
BINARY_CANDIDATES = [
    "target/x86_64-unknown-linux-gnu/release/tunnel",
    "tests/fuzz/target/x86_64-unknown-linux-gnu/release/tunnel",
]
# Only the sans-IO core is gated; the IO shell and everything else is excluded.
CRATE = "libs/connlib/tunnel-proto/src/"


def llvm_cov() -> str:
    toolchain = os.environ.get("COVERAGE_TOOLCHAIN", "nightly")
    sysroot = subprocess.check_output(
        ["rustc", f"+{toolchain}", "--print", "sysroot"], text=True
    ).strip()
    return os.path.join(
        sysroot, "lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov"
    )


def binary() -> str:
    for p in BINARY_CANDIDATES:
        if os.path.exists(p):
            return p
    return ""


def main() -> int:
    threshold = float(sys.argv[1]) if len(sys.argv) > 1 else 65.0
    bin_path = binary()
    if not os.path.exists(PROFDATA) or not bin_path:
        print(f"::error::coverage artifacts missing (profdata={PROFDATA!r}, "
              f"binary={bin_path or 'not found'})", file=sys.stderr)
        return 2

    export = subprocess.run(
        [llvm_cov(), "export", "-format=text",
         f"-instr-profile={PROFDATA}", bin_path],
        capture_output=True, text=True, check=True,
    )
    data = json.loads(export.stdout)

    covered = total = 0
    for exp in data["data"]:
        for file in exp["files"]:
            if CRATE in file["filename"]:
                r = file["summary"]["regions"]
                covered += r["covered"]
                total += r["count"]

    pct = 100.0 * covered / total if total else 0.0
    print(f"tunnel-proto region coverage: {covered}/{total} = {pct:.2f}% "
          f"(threshold {threshold:.2f}%)")
    if pct < threshold:
        print(f"::error::tunnel-proto coverage {pct:.2f}% < {threshold:.2f}% — "
              f"the committed corpus regressed; grow it via the nightly fuzz job.",
              file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
