package dev.firezone.android.features.signin.presentation

internal sealed class SignInViewAction {
    object NavigateToAuthActivity : SignInViewAction()
}
