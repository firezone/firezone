// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import java.security.MessageDigest

// Only the hash leaves the app. The token needs the nonce itself.
internal fun nonceHash(nonce: String): String =
    MessageDigest
        .getInstance("SHA-256")
        .digest(nonce.toByteArray(Charsets.UTF_8))
        .joinToString("") { "%02x".format(it) }
