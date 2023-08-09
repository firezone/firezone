package dev.firezone.android.features.auth.ui

internal sealed class AuthViewAction {

    data class LaunchAuthFlow(val url: String) : AuthViewAction()

    object AuthFlowComplete : AuthViewAction()

    object ShowError : AuthViewAction()
}
