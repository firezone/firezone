# This script must run from an elevated shell so that Firezone won't try to elevate

set -euo pipefail

BUNDLE_ID="dev.firezone.client"
DUMP_PATH="$LOCALAPPDATA/$BUNDLE_ID/data/logs/last_crash.dmp"

# Delete the crash file if present
rm -f "$DUMP_PATH"

# Ignore the exit code, this is supposed to crash
cargo run -p firezone-gui-client -- --crash || true

# Fail if the crash file wasn't written
stat "$DUMP_PATH"
rm "$DUMP_PATH"
