// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.core

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.tunnel.MockSessionFactory

/**
 * Starts the app with connlib and the portal stood in for, the way `--mock-tunnel` and
 * `--skip-portal-auth` do for the GUI client. Debug builds only; see `mise run //kotlin/android:dev-mock`.
 *
 * Both stand-ins are on unless an extra turns one off, so either half can be exercised against the
 * real other half:
 *
 *     adb shell am start -n dev.firezone.android/dev.firezone.android.core.MockLaunchActivity \
 *       --ez skipPortalAuth false
 */
class MockLaunchActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (intent.getBooleanExtra("mockTunnel", true)) {
            DebugOverrides.sessionFactory = MockSessionFactory
        }
        DebugOverrides.skipPortalAuth = intent.getBooleanExtra("skipPortalAuth", true)

        startActivity(
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TASK or Intent.FLAG_ACTIVITY_NEW_TASK
            },
        )
        finish()
    }
}
