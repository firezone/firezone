// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

import androidx.lifecycle.SavedStateHandle

internal class AuthRequestState(
    private val savedStateHandle: SavedStateHandle,
) {
    private var isGenerating = false

    val issuedUrl: String?
        get() = savedStateHandle[AUTH_REQUEST_URL_KEY]

    fun claimGeneration(): Boolean {
        if (isGenerating || issuedUrl != null) {
            return false
        }

        isGenerating = true
        return true
    }

    fun markIssued(url: String) {
        savedStateHandle[AUTH_REQUEST_URL_KEY] = url
    }

    fun releaseGeneration() {
        isGenerating = false
    }

    private companion object {
        private const val AUTH_REQUEST_URL_KEY = "authRequestUrl"
    }
}
