package dev.firezone.android.features.session.presentation

internal sealed class SessionViewAction {

    object NavigateToSignInFragment : SessionViewAction()

    object ShowError : SessionViewAction()
}
