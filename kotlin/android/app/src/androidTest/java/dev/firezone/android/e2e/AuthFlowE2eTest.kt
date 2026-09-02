// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.app.Activity
import android.app.Instrumentation.ActivityResult
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.net.Uri
import androidx.browser.auth.AuthTabIntent
import androidx.test.core.app.ApplicationProvider
import androidx.test.espresso.intent.ActivityResultFunction
import androidx.test.espresso.intent.Intents.intended
import androidx.test.espresso.intent.Intents.intending
import androidx.test.espresso.intent.matcher.IntentMatchers.hasAction
import androidx.test.espresso.intent.matcher.IntentMatchers.hasComponent
import androidx.test.espresso.intent.matcher.IntentMatchers.hasExtra
import androidx.test.espresso.intent.matcher.IntentMatchers.hasFlag
import androidx.test.espresso.intent.matcher.IntentMatchers.hasFlags
import androidx.test.espresso.intent.rule.IntentsRule
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import dev.firezone.android.core.data.TokenStore
import dev.firezone.android.core.presentation.MainActivity
import dev.firezone.android.features.auth.AUTH_CALLBACK_SCHEME
import dev.firezone.android.features.auth.PendingAuthSession
import dev.firezone.android.features.auth.ui.AuthActivity
import dev.firezone.android.tunnel.FakeSession
import dev.firezone.android.tunnel.FakeSessionFactory
import dev.firezone.android.tunnel.TestRestrictions
import dev.firezone.android.tunnel.finishAllActivities
import dev.firezone.android.tunnel.grantNotificationPermission
import dev.firezone.android.tunnel.grantVpnConsent
import dev.firezone.android.tunnel.stopTunnelService
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.hamcrest.Matcher
import org.hamcrest.Matchers.allOf
import org.hamcrest.Matchers.not
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import java.util.concurrent.atomic.AtomicReference
import javax.inject.Inject

@HiltAndroidTest
class AuthFlowE2eTest {
    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val intentsRule = IntentsRule()

    @Inject
    internal lateinit var tokenStore: TokenStore

    @Inject
    lateinit var preferences: SharedPreferences

    @Inject
    internal lateinit var pendingAuthSession: PendingAuthSession

    @Before
    fun setUp() {
        hiltRule.inject()
        grantVpnConsent()
        grantNotificationPermission()
        FakeSessionFactory.reset()
        finishAllActivities()
        stopTunnelService()
        preferences.edit().clear().commit()
        TestRestrictions.bundle.clear()
    }

    @Test
    fun authTabResultCompletesSignIn() =
        runBlocking {
            val attempt = stubAuthTab(Activity.RESULT_OK)

            launchAuthActivity()

            val session = awaitSession()
            val captured = checkNotNull(attempt.get())
            assertEquals(captured.token, tokenStore.get())
            assertEquals(captured.token, session.config.token)
            assertFalse(pendingAuthSession.hasPendingRequest())
            intended(authTabIntent())
            intended(mainActivityHandoffIntent())
        }

    @Test
    fun regularCustomTabFallbackCompletesSignInAfterCanceledResult() =
        runBlocking {
            val attempt = stubAuthTab(Activity.RESULT_CANCELED)

            launchAuthActivity()

            intended(mainActivityReturnIntent())
            val captured = checkNotNull(attempt.get())
            assertTrue(pendingAuthSession.hasPendingRequest())

            targetContext.startActivity(
                Intent(Intent.ACTION_VIEW, callbackUri(captured.state))
                    .setPackage(targetContext.packageName)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )

            val session = awaitSession()
            assertEquals(captured.token, tokenStore.get())
            assertEquals(captured.token, session.config.token)
            assertFalse(pendingAuthSession.hasPendingRequest())
            intended(authTabIntent())
            intended(mainActivityHandoffIntent())
        }

    private fun stubAuthTab(resultCode: Int): AtomicReference<AuthAttempt> {
        val captured = AtomicReference<AuthAttempt>()

        intending(authTabIntent()).respondWithFunction(
            ActivityResultFunction { intent ->
                val url = checkNotNull(intent.data)
                val attempt =
                    AuthAttempt(
                        nonce = checkNotNull(url.getQueryParameter("nonce")),
                        state = checkNotNull(url.getQueryParameter("state")),
                    )
                captured.set(attempt)

                val result =
                    if (resultCode == Activity.RESULT_OK) {
                        Intent().setData(callbackUri(attempt.state))
                    } else {
                        null
                    }
                ActivityResult(resultCode, result)
            },
        )

        return captured
    }

    private fun launchAuthActivity() {
        targetContext.startActivity(
            Intent(targetContext, AuthActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )
    }

    private fun callbackUri(state: String): Uri =
        Uri
            .Builder()
            .scheme(AUTH_CALLBACK_SCHEME)
            .authority(AUTH_CALLBACK_HOST)
            .appendQueryParameter("state", state)
            .appendQueryParameter("fragment", AUTH_FRAGMENT)
            .build()

    private suspend fun awaitSession(): FakeSession = withTimeout(TIMEOUT_MS) { FakeSessionFactory.awaitSession() }

    private fun authTabIntent(): Matcher<Intent> =
        allOf(
            hasAction(Intent.ACTION_VIEW),
            hasExtra(AuthTabIntent.EXTRA_LAUNCH_AUTH_TAB, true),
            hasExtra(AuthTabIntent.EXTRA_REDIRECT_SCHEME, AUTH_CALLBACK_SCHEME),
        )

    private fun mainActivityReturnIntent(): Matcher<Intent> =
        allOf(
            hasComponent(MainActivity::class.java.name),
            not(hasFlag(Intent.FLAG_ACTIVITY_CLEAR_TASK)),
        )

    private fun mainActivityHandoffIntent(): Matcher<Intent> =
        allOf(
            hasComponent(MainActivity::class.java.name),
            hasFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK),
        )

    private data class AuthAttempt(
        val nonce: String,
        val state: String,
    ) {
        val token: String = nonce + AUTH_FRAGMENT
    }

    private val targetContext: Context
        get() = ApplicationProvider.getApplicationContext()

    private companion object {
        const val AUTH_CALLBACK_HOST = "handle_client_sign_in_callback"
        const val AUTH_FRAGMENT = "auth-fragment"
        const val TIMEOUT_MS = 20_000L
    }
}
