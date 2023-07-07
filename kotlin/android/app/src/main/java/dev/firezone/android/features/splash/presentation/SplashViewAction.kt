package dev.firezone.android.features.splash.presentation

internal sealed class SplashViewAction {
    object NavigateToOnboardingFragment : SplashViewAction()
    object NavigateToSignInFragment : SplashViewAction()
    object NavigateToSessionFragment : SplashViewAction()
}
