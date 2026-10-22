// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.e2e

import android.app.Activity
import android.app.Instrumentation.ActivityResult
import android.content.Intent
import android.net.Uri
import androidx.browser.auth.AuthTabIntent
import androidx.test.espresso.intent.ActivityResultFunction
import androidx.test.espresso.intent.Intents.intending
import androidx.test.espresso.intent.matcher.IntentMatchers.hasAction
import androidx.test.espresso.intent.matcher.IntentMatchers.hasExtra
import dev.firezone.android.features.auth.AUTH_CALLBACK_SCHEME
import org.hamcrest.Matcher
import org.hamcrest.Matchers.allOf
import java.util.concurrent.atomic.AtomicReference

private const val AUTH_CALLBACK_HOST = "handle_client_sign_in_callback"
private const val AUTH_FRAGMENT = "auth-fragment"

// What the app asked the browser to sign in with. The portal would hand the fragment back through
// the callback, so together they are the token the app ends up storing.
internal data class AuthAttempt(
    val nonce: String,
    val state: String,
) {
    val token: String = nonce + AUTH_FRAGMENT
}

// Stands in for the browser: answers the AuthTab with [resultCode] the moment it is launched and
// records what it was launched with. Needs Espresso Intents to be initialised.
internal fun stubAuthTab(resultCode: Int): AtomicReference<AuthAttempt> {
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

internal fun callbackUri(state: String): Uri =
    Uri
        .Builder()
        .scheme(AUTH_CALLBACK_SCHEME)
        .authority(AUTH_CALLBACK_HOST)
        .appendQueryParameter("state", state)
        .appendQueryParameter("fragment", AUTH_FRAGMENT)
        .build()

internal fun authTabIntent(): Matcher<Intent> =
    allOf(
        hasAction(Intent.ACTION_VIEW),
        hasExtra(AuthTabIntent.EXTRA_LAUNCH_AUTH_TAB, true),
        hasExtra(AuthTabIntent.EXTRA_REDIRECT_SCHEME, AUTH_CALLBACK_SCHEME),
    )
