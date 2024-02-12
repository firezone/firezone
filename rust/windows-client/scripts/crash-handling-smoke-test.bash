# This script must run from an elevated shell so that Firezone won't try to elevate

set -euo pipefail

BUNDLE_ID="dev.firezone.client"
DUMP_PATH="$LOCALAPPDATA/$BUNDLE_ID/data/logs/last_crash.dmp"

rm -f "$DUMP_PATH"

cargo run -p firezone-windows-client -- --crash || true

stat "$DUMP_PATH"
rm "$DUMP_PATH"
