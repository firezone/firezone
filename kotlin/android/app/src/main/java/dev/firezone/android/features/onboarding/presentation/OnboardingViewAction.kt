package dev.firezone.android.features.onboarding.presentation

internal sealed class OnboardingViewAction {
    object NavigateToSignInFragment : OnboardingViewAction()
    data class FillPortalUrl(val value: String) : OnboardingViewAction()
}
