// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.customuri.ui

import android.app.Application
import android.content.Intent
import dev.firezone.android.core.presentation.MainActivity
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(application = Application::class)
class CustomUriHandlerActivityTest {
    @Test
    fun `main activity handoff replaces authentication task`() {
        val context = RuntimeEnvironment.getApplication()

        val intent = mainActivityHandoffIntent(context)

        assertEquals(MainActivity::class.java.name, intent.component?.className)
        assertEquals(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK, intent.flags)
    }
}
