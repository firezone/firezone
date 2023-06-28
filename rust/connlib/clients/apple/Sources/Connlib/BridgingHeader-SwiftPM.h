// This header is used in `build.rs`, and is exactly the same as
// `BridgingHeader.h` *except* the `include` paths are relative.
//
// Attempting to build an `xcframework` with a quoted `include` violates rules
// around non-modular imports, as only headers specified as part of the module
// can be included.
//
// However, SwiftPM has no equivalent to "modular headers", so we can only rely
// on normal, simple `include` paths.

#ifndef BridgingHeader_h
#define BridgingHeader_h

#include "Generated/SwiftBridgeCore.h"
#include "Generated/connlib-apple/connlib-apple.h"

#endif
