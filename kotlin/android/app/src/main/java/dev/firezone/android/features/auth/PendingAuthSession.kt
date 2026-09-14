// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth

import android.net.Uri
import java.security.MessageDigest
import javax.inject.Inject
import javax.inject.Singleton

internal const val AUTH_CALLBACK_SCHEME = "firezone-fd0020211111"

@Singleton
internal class PendingAuthSession
    @Inject
    constructor() {
        private val lock = Any()
        private var pendingRequest: PendingRequest? = null

        fun begin(
            nonce: String,
            state: String,
        ) {
            require(nonce.isNotBlank())
            require(state.isNotBlank())

            synchronized(lock) {
                pendingRequest = PendingRequest(nonce = nonce, state = state)
            }
        }

        fun complete(uri: Uri?): AuthCallbackOutcome {
            val callback =
                when (val parsed = parseCallback(uri)) {
                    is ParsedCallback.Invalid -> return AuthCallbackOutcome.Error(parsed.errors)
                    is ParsedCallback.Valid -> parsed
                }

            return synchronized(lock) {
                val request =
                    pendingRequest
                        ?: return@synchronized AuthCallbackOutcome.Error("No pending authentication request")

                if (!constantTimeEquals(request.state, callback.state)) {
                    return@synchronized AuthCallbackOutcome.Error("Invalid state parameter")
                }

                pendingRequest = null
                AuthCallbackOutcome.Success(request.nonce + callback.fragment)
            }
        }

        fun cancel(state: String) {
            synchronized(lock) {
                val request = pendingRequest ?: return@synchronized
                if (constantTimeEquals(request.state, state)) {
                    pendingRequest = null
                }
            }
        }

        fun hasPendingRequest(): Boolean = synchronized(lock) { pendingRequest != null }

        private fun parseCallback(uri: Uri?): ParsedCallback {
            if (uri?.scheme != AUTH_CALLBACK_SCHEME || uri.host != AUTH_CALLBACK_HOST) {
                return ParsedCallback.Invalid("Unknown authentication callback URI")
            }

            val state = uri.getQueryParameter(QUERY_CLIENT_STATE)
            val fragment = uri.getQueryParameter(QUERY_CLIENT_AUTH_FRAGMENT)
            val errors =
                buildList {
                    if (state.isNullOrBlank()) {
                        add("State parameter was missing or empty")
                    }
                    if (fragment.isNullOrBlank()) {
                        add("Auth fragment was missing or empty")
                    }
                }

            if (errors.isNotEmpty()) {
                return ParsedCallback.Invalid(errors)
            }

            return ParsedCallback.Valid(
                state = checkNotNull(state),
                fragment = checkNotNull(fragment),
            )
        }

        private fun constantTimeEquals(
            expected: String,
            actual: String,
        ): Boolean =
            MessageDigest.isEqual(
                expected.toByteArray(Charsets.UTF_8),
                actual.toByteArray(Charsets.UTF_8),
            )

        private data class PendingRequest(
            val nonce: String,
            val state: String,
        )

        private sealed interface ParsedCallback {
            data class Valid(
                val state: String,
                val fragment: String,
            ) : ParsedCallback

            data class Invalid(
                val errors: List<String>,
            ) : ParsedCallback {
                constructor(vararg errors: String) : this(errors.toList())
            }
        }

        private companion object {
            const val AUTH_CALLBACK_HOST = "handle_client_sign_in_callback"
            const val QUERY_CLIENT_STATE = "state"
            const val QUERY_CLIENT_AUTH_FRAGMENT = "fragment"
        }
    }

internal sealed interface AuthCallbackOutcome {
    data class Success(
        val token: String,
    ) : AuthCallbackOutcome

    data class Error(
        val errors: List<String>,
    ) : AuthCallbackOutcome {
        constructor(vararg errors: String) : this(errors.toList())
    }
}
