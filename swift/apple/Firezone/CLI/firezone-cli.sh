#!/bin/sh
# Installed into /usr/local/bin as firezone-cli. A symlink would not do: macOS derives an
# app's bundle from the path its binary was launched through, so a link from outside the
# bundle leaves the client without the app's identity. Starting the binary at its real
# path keeps it.
exec /Applications/Firezone.app/Contents/MacOS/firezone-cli "$@"
