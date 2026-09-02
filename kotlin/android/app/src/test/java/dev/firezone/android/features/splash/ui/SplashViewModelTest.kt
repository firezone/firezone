// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.splash.ui

import android.app.Application
import android.content.Context
import android.os.Bundle
import android.os.Looper
import androidx.lifecycle.SavedStateHandle
import dev.firezone.android.core.ApplicationMode
import dev.firezone.android.core.data.Repository
import dev.firezone.android.core.x509.CertificateAccess
import dev.firezone.android.core.x509.SystemKeyChain
import kotlinx.coroutines.Dispatchers
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode
import java.util.concurrent.TimeUnit

@RunWith(RobolectricTestRunner::class)
@LooperMode(LooperMode.Mode.PAUSED)
@Config(
    sdk = [34],
    application = Application::class,
)
class SplashViewModelTest {
    @Test
    fun `cancelling a tunnel state check prevents delayed navigation`() {
        val context = RuntimeEnvironment.getApplication()
        val viewModel = newViewModel(context)

        viewModel.checkTunnelState(context)
        viewModel.cancelTunnelStateCheck()
        shadowOf(Looper.getMainLooper()).idleFor(2, TimeUnit.SECONDS)

        assertNull(viewModel.actionStateFlow.value)
    }

    @Test
    fun `cancelling a tunnel state check clears delayed navigation`() {
        val context = RuntimeEnvironment.getApplication()
        val viewModel = newViewModel(context)

        viewModel.checkTunnelState(context)
        shadowOf(Looper.getMainLooper()).idleFor(2, TimeUnit.SECONDS)
        assertNotNull(viewModel.actionStateFlow.value)

        viewModel.cancelTunnelStateCheck()

        assertNull(viewModel.actionStateFlow.value)
    }

    private fun newViewModel(context: Context): SplashViewModel {
        val repository =
            Repository(
                context = context,
                coroutineDispatcher = Dispatchers.Unconfined,
                sharedPreferences = context.getSharedPreferences("splash-view-model-test", Context.MODE_PRIVATE),
            )
        val applicationRestrictions = Bundle()
        val certificateAccess =
            CertificateAccess(repository, applicationRestrictions, SystemKeyChain(context))

        return SplashViewModel(
            repo = repository,
            applicationRestrictions = applicationRestrictions,
            applicationMode = ApplicationMode.TESTING,
            certificateAccess = certificateAccess,
            savedStateHandle = SavedStateHandle(),
        )
    }
}
