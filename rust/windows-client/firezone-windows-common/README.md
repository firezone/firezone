firezone-windows-common

This is needed because the `wintun.dll` path needs to be guaranteed consistent
between connlib and the Windows client.

This path ultimately depends only on `BUNDLE_ID`.

Injecting the BUNDLE_ID into connlib, or retrieving it from connlib, would
have required connlib's public API to change.

And connlib must call `wintun::load_from_path` so that it can call `wintun::Adapter::create`,
so loading wintun in the GUI module would not be enough.
