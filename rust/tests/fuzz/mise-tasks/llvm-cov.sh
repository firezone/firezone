#!/usr/bin/env bash
#MISE description="Run the nightly toolchain's llvm-cov, e.g. to post-process coverage.profdata"
#MISE depends=["install-toolchain"]
#MISE raw=true
#USAGE arg "<llvm_cov_args>" var=#true
set -euo pipefail
cd "$(dirname "$0")/.."

# `usage` joins variadic arguments as a shell-escaped string.
eval "set -- ${usage_llvm_cov_args:-}"

"$(rustc --print sysroot)/lib/rustlib/x86_64-unknown-linux-gnu/bin/llvm-cov" "$@"
