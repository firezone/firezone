// Licensed under Apache 2.0 (C) 2026 Firezone, Inc.
package dev.firezone.android.features.auth.ui

internal enum class AuthBrowserState {
    NOT_STARTED,
    LAUNCHED,
    UNAVAILABLE,
    ;

    fun resumeAction(): Action =
        when (this) {
            NOT_STARTED -> Action.START_AUTH_FLOW
            LAUNCHED -> Action.NAVIGATE_TO_SIGN_IN
            UNAVAILABLE -> Action.NONE
        }

    fun browserRequiredAcknowledgementAction(): Action =
        when (this) {
            UNAVAILABLE -> Action.NAVIGATE_TO_SIGN_IN
            NOT_STARTED, LAUNCHED -> Action.NONE
        }

    enum class Action {
        START_AUTH_FLOW,
        NAVIGATE_TO_SIGN_IN,
        NONE,
    }

    companion object {
        fun restore(value: String?): AuthBrowserState = entries.firstOrNull { it.name == value } ?: NOT_STARTED
    }
}
