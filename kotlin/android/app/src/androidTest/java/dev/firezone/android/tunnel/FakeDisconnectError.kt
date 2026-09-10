// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import uniffi.connlib.DisconnectError
import uniffi.connlib.NoHandle

// UniFFI hands out `NoHandle` constructors precisely so foreign code can build these
// without a live Rust object behind them.
class FakeDisconnectError(
    private val signInRequired: Boolean,
    private val text: String = "session ended",
) : DisconnectError(NoHandle) {
    override fun userMessage(): String = text

    override fun logMessage(): String = text

    override fun requiresSignIn(): Boolean = signInRequired
}
