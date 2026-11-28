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
import dev.firezone.android.features.auth.AUTH_HTTPS_CALLBACK_PATH
import dev.firezone.android.features.auth.nonceHash
import org.hamcrest.Matcher
import org.hamcrest.Matchers.allOf
import org.hamcrest.Matchers.anyOf
import java.util.concurrent.atomic.AtomicReference

private const val AUTH_CALLBACK_HOST = "handle_client_sign_in_callback"
private const val AUTH_FRAGMENT = "auth-fragment"

// What the app asked the browser to sign in with. The portal would hand the fragment back through
// the callback, and the app joins it to the nonce whose hash it sent.
internal data class AuthAttempt(
    val nonceHash: String,
    val state: String,
) {
    fun isToken(token: String?): Boolean =
        token != null &&
            token.endsWith(AUTH_FRAGMENT) &&
            nonceHash(token.removeSuffix(AUTH_FRAGMENT)) == nonceHash
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
                    nonceHash = checkNotNull(url.getQueryParameter("nonce_hash")),
                    state = checkNotNull(url.getQueryParameter("state")),
                )
            captured.set(attempt)

            val httpsHost = intent.getStringExtra(AuthTabIntent.EXTRA_HTTPS_REDIRECT_HOST)
            val result =
                if (resultCode == Activity.RESULT_OK) {
                    Intent().setData(if (httpsHost != null) httpsCallbackUri(httpsHost, attempt.state) else callbackUri(attempt.state))
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

private fun httpsCallbackUri(
    host: String,
    state: String,
): Uri =
    Uri
        .Builder()
        .scheme("https")
        .authority(host)
        .path(AUTH_HTTPS_CALLBACK_PATH)
        .encodedFragment(
            Uri
                .Builder()
                .appendQueryParameter("state", state)
                .appendQueryParameter("fragment", AUTH_FRAGMENT)
                .build()
                .encodedQuery,
        ).build()

// Whether the emulator's browser supports Auth Tab decides which redirect the app asks for.
internal fun authTabIntent(): Matcher<Intent> =
    allOf(
        hasAction(Intent.ACTION_VIEW),
        hasExtra(AuthTabIntent.EXTRA_LAUNCH_AUTH_TAB, true),
        anyOf(
            hasExtra(AuthTabIntent.EXTRA_REDIRECT_SCHEME, AUTH_CALLBACK_SCHEME),
            hasExtra(AuthTabIntent.EXTRA_HTTPS_REDIRECT_PATH, AUTH_HTTPS_CALLBACK_PATH),
        ),
    )
