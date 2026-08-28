// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

internal enum class AuthBrowserState {
    NOT_STARTED,
    LAUNCHED,
    UNAVAILABLE,
    ;

    fun resumeAction(): ResumeAction =
        when (this) {
            NOT_STARTED -> ResumeAction.START_AUTH_FLOW
            LAUNCHED -> ResumeAction.NAVIGATE_TO_SIGN_IN
            UNAVAILABLE -> ResumeAction.NONE
        }

    enum class ResumeAction {
        START_AUTH_FLOW,
        NAVIGATE_TO_SIGN_IN,
        NONE,
    }

    companion object {
        fun restore(value: String?): AuthBrowserState = entries.firstOrNull { it.name == value } ?: NOT_STARTED
    }
}
