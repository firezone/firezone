// Licensed under Apache 2.0 (C) 2024 Firezone, Inc.
package dev.firezone.android.core

enum class ApplicationMode {
    NORMAL,

    /** Instrumented tests: no real VPN to grant permission for. */
    TESTING,

    /** A debug launch against a mocked connlib: likewise no real VPN. */
    MOCK,
}
