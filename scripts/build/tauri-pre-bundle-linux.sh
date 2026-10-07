#!/usr/bin/env bash
# Driven by `tauri.linux.conf.json:beforeBundleCommand`. Moves the debug info
# of the binaries we ship into `.debug` files, which we upload to Sentry.
set -euxo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/../../rust/target/release"

for bin in firezone-client-gui firezone-client-tunnel firezone-cli register-sparse; do
    objcopy --only-keep-debug "$bin" "$bin.debug"
    objcopy --strip-debug --add-gnu-debuglink="$bin.debug" "$bin"
done
