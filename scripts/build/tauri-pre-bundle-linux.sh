#!/usr/bin/env bash
# Driven by `tauri-release-linux.conf.json:beforeBundleCommand`. Moves the debug
# info of the binaries we ship into `.debug` files, which we upload to Sentry.
set -euxo pipefail

cd "$TARGET_DIR/release"

for bin in firezone-client-gui firezone-client-tunnel firezone-cli register-sparse; do
    objcopy --only-keep-debug "$bin" "$bin.debug"
    objcopy --strip-debug --add-gnu-debuglink="$bin.debug" "$bin"
done
