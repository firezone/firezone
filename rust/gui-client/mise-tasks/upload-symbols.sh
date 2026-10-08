#!/usr/bin/env bash
#MISE description="Upload the debug symbols of the release build to Sentry"
#MISE dir="{{config_root}}"
set -euxo pipefail

cd ../target/release

case "$OSTYPE" in
linux*) files=(firezone-client-gui{,.debug} firezone-client-tunnel{,.debug}) ;;
*) files=(Firezone.exe firezone_gui_client.pdb firezone-client-tunnel.exe firezone_client_tunnel.pdb register-sparse.exe register_sparse.pdb) ;;
esac

# Only the binaries we ship. Intermediate object files can reference a
# directory instead of a source file, which aborts the upload.
sentry-cli debug-files upload --log-level info --project gui-client --include-sources "${files[@]}"
