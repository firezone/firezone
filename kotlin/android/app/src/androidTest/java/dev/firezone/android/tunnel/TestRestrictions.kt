// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.tunnel

import android.os.Bundle

// Stands in for the managed configuration a device owner would push. Process-wide for the same
// reason as the session factory: the service reading it may predate the test writing it.
object TestRestrictions {
    val bundle = Bundle()
}
